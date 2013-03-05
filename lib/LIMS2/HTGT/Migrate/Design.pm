package LIMS2::HTGT::Migrate::Design;

use strict;
use warnings FATAL => 'all';

use Sub::Exporter -setup => {
    exports => [ qw( get_design_data get_target_region_slice get_target_gene get_target_transcript ) ]
};

use Const::Fast;
use DateTime;
use LIMS2::HTGT::Migrate::Utils qw( parse_oracle_date canonical_username );
use HTGT::Utils::DesignPhase qw( get_phase_from_design_and_transcript phase_warning_comment );
use List::MoreUtils qw( uniq );
use Log::Log4perl qw( :easy );
use Try::Tiny;
use Bio::EnsEMBL::Registry;

const my $SPECIES => 'mouse';

my $registry = 'Bio::EnsEMBL::Registry';
$registry->load_registry_from_db(
    -host => $ENV{HTGT_ENSEMBL_HOST} || 'ens-livemirror.internal.sanger.ac.uk',
    -user => $ENV{HTGT_ENSEMBL_USER} || 'ensro'
);

my $slice_adaptor = $registry->get_adaptor( $SPECIES, 'core', 'slice' );
my $gene_adaptor = $registry->get_adaptor( $SPECIES, 'core', 'gene' );

const my $ASSEMBLY => 'GRCm38';

const my @GENOTYPING_PRIMER_NAMES => qw( GF1 GF2 GF3 GF4
                                         GR1 GR2 GR3 GR4
                                         LF1 LF2 LF3
                                         LR1 LR2 LR3
                                         PNFLR1 PNFLR2 PNFLR3
                                         EX3 EX32 EX5 EX52 );

const my @OLIGO_NAMES => qw( G5 U5 U3 D5 D3 G3 );

sub get_design_data {
    my ( $design, $target_gene ) = @_;

    DEBUG( "get_design_data" );

    my $run_date = DateTime->now;

    my $type         = type_for( $design );
    my $oligos       = oligos_for( $design, $type );
    my $created_date = parse_oracle_date( $design->created_date ) || $run_date;
    my $transcript   = target_transcript_for( $design, $target_gene );
    die 'No transcript found for design' unless $transcript;
    return {
        id                      => $design->design_id,
        name                    => $design->find_or_create_name,
        type                    => $type,
        created_by              => ( $design->created_user ? canonical_username( $design->created_user) : 'unknown' ),
        created_at              => $created_date->iso8601,
        phase                   => get_phase_from_design_and_transcript( $design, $transcript->stable_id ),
        validated_by_annotation => $design->validated_by_annotation || '',
        oligos                  => $oligos,
        genotyping_primers      => genotyping_primers_for( $design ),
        comments                => comments_for( $design, $created_date, $transcript->stable_id ),
        target_transcript       => $transcript ? $transcript->stable_id : undef,
        gene_ids                => gene_ids_for( $design ),
        species                 => 'Mouse',
    };
}

sub oligos_for {
    my ( $design, $design_type ) = @_;

    my @oligos;

    my $features = $design->validated_display_features;

    for my $oligo_name ( @OLIGO_NAMES ) {
        my $oligo = $features->{$oligo_name} or next;
        my @oligo_seq = grep { $_->feature_data_type->description eq 'sequence' } $oligo->feature->feature_data;
        unless ( @oligo_seq == 1 ) {
            WARN( 'Found ' . @oligo_seq . ' sequences for oligo ' . $oligo_name );
            next;
        }
        push @oligos, {
            type => $oligo_name,
            seq  => $oligo_seq[0]->data_item,
            loci => [
                {
                    assembly   => $ASSEMBLY,
                    chr_name   => $oligo->chromosome->name,
                    chr_start  => $oligo->feature_start,
                    chr_end    => $oligo->feature_end,
                    chr_strand => $oligo->feature_strand
                }
            ]
        };
    }

    sanity_check_oligos( $design_type, \@oligos );

    return \@oligos;
}

sub sanity_check_oligos {
    my ( $design_type, $oligos ) = @_;

    die "Design has no validated oligos with $ASSEMBLY locus\n"
        unless @{$oligos} > 1;

    my %loci = map { $_->{type} => $_->{loci}[0] } @{$oligos};

    my @chromosomes = uniq map { $_->{chr_name} } values %loci;
    die "Oligos have inconsistent chromosome\n" unless @chromosomes == 1;

    my @strands = uniq map { $_->{chr_strand} } values %loci;
    die "Oligos have inconsistent strand\n" unless @strands == 1;

    my @oligo_names = $strands[0] eq 1 ? @OLIGO_NAMES : reverse @OLIGO_NAMES;

    if ( $design_type eq 'insertion' or $design_type eq 'deletion' ) {
        @oligo_names = grep { $_ ne 'U3' and $_ ne 'D5' } @oligo_names;
    }

    for my $o ( @oligo_names ) {
        my $locus = $loci{$o};
        die "Expected oligo oligo $o has no locus\n"
            unless $locus;
        die "Oligo $o has end before start\n"
            unless $locus->{chr_end} > $locus->{chr_start};
    }

    for my $ix ( 0 .. (@oligo_names - 2) ) {
        my $o1 = $oligo_names[$ix];
        my $o2 = $oligo_names[$ix+1];
        die "Oligos $o1 and $o2 in unexpected order\n"
            unless $loci{$o1}{chr_end} <= $loci{$o2}{chr_start};
    }
}

sub genotyping_primers_for {
    my $design = shift;

    my @genotyping_primers;

    my $feature_rs = $design->search_related(
        features => {
            'feature_type.description' => \@GENOTYPING_PRIMER_NAMES
        },
        {
            join     => [ 'feature_type' ],
            prefetch => [ 'feature_type', { 'feature_data' => 'feature_data_type' } ]
        }
    );

    while ( my $feature = $feature_rs->next ) {
        my @primer_seq = grep { $_->feature_data_type->description eq 'sequence' } $feature->feature_data;
        unless ( @primer_seq == 1 ) {
            WARN( 'Found ' . @primer_seq . ' sequences for genotyping primer ' . $feature->feature_type->description );
            next;
        }
        push @genotyping_primers, {
            type => $feature->feature_type->description,
            seq  => $primer_seq[0]->data_item
        }
    }

    return \@genotyping_primers;
}

sub comments_for {
    my ( $design, $created_date, $transcript_id ) = @_;

    my @comments;
    for my $comment ( $design->design_user_comments ) {
        my $category = $comment->category->category_name;
        next if $category eq 'Artificial intron design';
        my $created_at = parse_oracle_date( $comment->edited_date ) || $created_date;
        push @comments, {
            comment_text => $comment->design_comment,
            category     => $category,
            created_by   => ( $comment->edited_user ? canonical_username( $comment->edited_user ) : 'unknown' ),
            created_at   => $created_date->iso8601,
            is_public    => $comment->visibility eq 'public'
        };
    }

    add_comment(\@comments, phase_warning_comment($transcript_id));

    return \@comments;
}

sub add_comment{
    my ( $comments, $comment_text) = @_;

    if ($comment_text){
        push @$comments, {
            comment_text => $comment_text,
            category     => 'Warning!',
            created_by   => 'htgt_migrate',
            created_at   => DateTime->today->iso8601,
            is_public    => 1
        };
        return 1;
    }
    return;
}

sub type_for {
    my $design = shift;

    my $intron_replacement =
        $design->search_related_rs( 'design_user_comments',
                                  {
                                      'category.category_name' => 'Intron replacement'
                              },
                              {
                                  join => 'category'
                              }
                          )->count;

    if ( $intron_replacement > 0 ) {
        return 'intron-replacement';
    }

    if ( $design->is_artificial_intron ) {
        return 'artificial-intron';
    }

    my $dt = $design->design_type;

    if ( !defined($dt) || $dt =~ /^KO/ ) {
        return 'conditional';
    }

    if ( $dt =~ /^Ins/ ) {
        return 'insertion';
    }

    if ( $dt =~ /^Del/ ) {
        return 'deletion';
    }

    die "Unrecognized design type '$dt'\n";
}

sub target_transcript_for {
    my ( $design, $target_gene ) = @_;

    my $target_transcript;
    try {
        $target_transcript = get_target_transcript( $design, $target_gene );
    } catch {
        s/ at .*$//s;
        WARN( "Error getting target transcript " . $_ );
    };

    return $target_transcript;
}

sub gene_ids_for {
    my ( $design ) = @_;

    my $projects = $design->result_source->storage->dbh_do(
        sub {
            $_[1]->selectcol_arrayref( <<'EOT', undef, $design->design_id );
select distinct mgi_gene.mgi_accession_id
from mgi_gene
join project on project.mgi_gene_id = mgi_gene.mgi_gene_id
where project.design_id = ?
EOT
        }
    );

    return $projects;
}

sub get_target_transcript {
    my ( $design, $target_gene_name ) = @_;

    my @best_transcripts;
    my $longest_transcript_length = 0;
    my $longest_translation_length = 0;

    my $target_gene = get_target_gene( $design, $target_gene_name );

    for my $transcript ( @{ $target_gene->get_all_Transcripts } ) {
        my $translation = $transcript->translation
            or next;
        if ( $translation->length > $longest_translation_length ) {
            @best_transcripts = ( $transcript );
            $longest_translation_length = $translation->length;
            $longest_transcript_length = $transcript->length;
        }
        elsif ( $translation->length == $longest_translation_length ) {
            if ( $transcript->length > $longest_transcript_length ) {
                @best_transcripts = ( $transcript );
                $longest_transcript_length = $transcript->length;
            }
            elsif ( $transcript->length == $longest_transcript_length ) {
                push @best_transcripts, $transcript;
            }
        }
    }

    die $target_gene->stable_id . ' has no coding transcripts'
        unless @best_transcripts;

    return shift @best_transcripts;
}

sub get_target_gene {
    my ( $design, $target_gene_name ) = @_;

    my $target_region_slice = get_target_region_slice( $design );

    my $exons = $target_region_slice->get_all_Exons;
    die "No exons found in target region"
        unless @{$exons};

    my %genes_in_target_region;
    for my $e ( @{$exons} ) {
        my $gene = $gene_adaptor->fetch_by_exon_stable_id( $e->stable_id );
        $genes_in_target_region{ $gene->stable_id } ||= $gene;
    }

    my $target_gene;

    if ( keys %genes_in_target_region == 1 ) {
        $target_gene = (values %genes_in_target_region)[0];
    }
    elsif ( $target_gene_name && exists $genes_in_target_region{ $target_gene_name } ) {
        $target_gene = $genes_in_target_region{$target_gene_name};
    }
    else {
        die 'multiple genes found in target region ' . join( ' ', keys %genes_in_target_region );
    }

    return $target_gene->transfer( $design->info->slice );
}

sub get_target_region_slice {
    my $design = shift;

    my $features = $design->validated_display_features;
    my $type = $design->design_type || 'KO';
    my $strand = $design->info->chr_strand;

    my ( $target_region_start, $target_region_end );

    if ( $type =~ /^Del/ || $type =~ /^Ins/ ) {
        if ( $strand == 1 ) {
            $target_region_start = $features->{U5}->feature_start;
            $target_region_end   = $features->{D3}->feature_end;
        }
        else {
            $target_region_start = $features->{D3}->feature_start;
            $target_region_end   = $features->{U5}->feature_end;
        }

    }
    # Knock Out Design
    else {
        if ( $strand == 1 ) {
            $target_region_start = $features->{U3}->feature_start;
            $target_region_end   = $features->{D5}->feature_end;
        }
        else {
            $target_region_start = $features->{D5}->feature_start;
            $target_region_end   = $features->{U3}->feature_end;
        }
    }

    return $slice_adaptor->fetch_by_region(
        'chromosome',
        $design->info->chr_name,
        $target_region_start,
        $target_region_end,
        $design->info->chr_strand
    );
}

1;

__END__
