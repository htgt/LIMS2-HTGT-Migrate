#!/usr/bin/env perl

use strict;
use warnings FATAL => 'all';

use HTGT::DBFactory;
use YAML::Any;
use DateTime;
use Log::Log4perl qw( :easy );
use Try::Tiny;
use Const::Fast;
use LIMS2::HTGT::Migrate::Utils qw( trim parse_oracle_date canonical_username );
use HTGT::Utils::EnsEMBL;
use List::MoreUtils qw( uniq );
use Getopt::Long;

const my $ASSEMBLY => 'NCBIM37';

const my @WANTED_DESIGN_STATUS => ( 'Ready to order', 'Ordered' );

const my @GENOTYPING_PRIMER_NAMES => qw( GF1 GF2 GF3 GF4
                                         GR1 GR2 GR3 GR4
                                         LF1 LF2 LF3
                                         LR1 LR2 LR3
                                         PNFLR1 PNFLR2 PNFLR3
                                         EX3 EX32 EX5 EX52 );

const my @OLIGO_NAMES => qw( G5 U5 U3 D5 D3 G3 );

GetOptions(
    'start=i' => \my $start_id,
    'end=i'   => \my $end_id
) or die "Usage: $0 [--start=START] [--end=END]\n";

Log::Log4perl->easy_init(
    {
        level  => $WARN,
        layout => '%p [design %x] %m%n'
    }
);

my $schema = HTGT::DBFactory->connect( 'eucomm_vector' );

my $run_date = DateTime->now;

my $designs_rs;

if ( @ARGV ) {
    $designs_rs = $schema->resultset( 'Design' )->search( { design_id => \@ARGV } );
}
else {
    my %search = (
        'statuses.is_current'            => 1,
        'design_status_dict.description' => \@WANTED_DESIGN_STATUS
    );
    if ( defined $start_id and defined $end_id ) {
        $search{'-and'} = [
            { 'me.design_id' => { '>=', $start_id } },
            { 'me.design_id' => { '<',  $end_id   } }
        ]
    }
    elsif ( defined $start_id ) {
        $search{'me.design_id'} = { '>=', $start_id };
    }
    elsif ( defined $end_id ) {
        $search{'me.design_id'} = { '<', $end_id };
    }
    $designs_rs = $schema->resultset( 'Design' )->search(
        \%search,
        {
            join => { 'statuses' => 'design_status_dict' },
            distinct => 1
        }
    );
}

while ( my $design = $designs_rs->next ) {
    Log::Log4perl::NDC->push( $design->design_id );
    try {
        my $type         = type_for( $design );
        my $oligos       = oligos_for( $design, $type );
        my $created_date = parse_oracle_date( $design->created_date ) || $run_date;
        my $transcript   = target_transcript_for( $design );        
        my %design = (
            id                      => $design->design_id,
            name                    => $design->find_or_create_name,
            type                    => $type,
            created_by              => ( $design->created_user ? canonical_username( $design->created_user) : 'unknown' ),
            created_at              => $created_date->iso8601,
            phase                   => phase_for( $oligos, $transcript, $type ),
            validated_by_annotation => $design->validated_by_annotation || '',
            oligos                  => $oligos,
            genotyping_primers      => genotyping_primers_for( $design ),
            comments                => comments_for( $design, $created_date ),
            target_transcript       => $transcript,
            gene_ids                => gene_ids_for( $design )                
        );
        print YAML::Any::Dump( \%design );
    }
    catch {
        ERROR($_);
    }
    finally {        
        Log::Log4perl::NDC->pop;        
    };    
}

sub oligos_for {
    my ( $design, $design_type ) = @_;

    my @oligos;

    my $features = validated_display_features_for( $design );    

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

    die "Design has no validated oligos with NCBIM37 locus\n"
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
    my ( $design, $created_date ) = @_;

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

    return \@comments;
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

sub phase_for {
    my ( $oligos, $transcript_id, $design_type ) = @_;

    unless ( $transcript_id ) {        
        WARN "Cannot compute phase without transcript";
        return undef;
    }    
    
    my ( $U5 ) = grep { $_->{type} eq 'U5' } @{$oligos};
    unless ( $U5 and @{$U5->{loci}} ) {
        WARN "Cannot compute phase without U5 oligo";
        return undef;
    }
    
    my $transcript = HTGT::Utils::EnsEMBL->transcript_adaptor->fetch_by_stable_id( $transcript_id );
    unless ( $transcript ) {
        WARN "Failed to retrieve transcript $transcript_id";
        return undef;
    }

    unless ( $transcript->coding_region_start ) {
        WARN "Non-coding transcript $transcript_id";
        return undef;
    }
    
    my $U5_locus = $U5->{loci}[0];

    # XXX Check for off-by-one errors in boundary cases
    if ( $U5_locus->{chr_strand} == 1 ) {
        my $cs = $U5_locus->{chr_end} + 1;
        if ( $transcript->coding_region_start > $cs or $transcript->coding_region_end < $cs ) {
            return -1;
        }
        my $coding_bases = 0;
        for my $e ( @{ $transcript->get_all_Exons } ) {
            next unless $e->coding_region_start( $transcript );
            last if $e->seq_region_start > $cs;
            if ( $e->seq_region_end < $cs ) {
                $coding_bases += $e->coding_region_end( $transcript ) - $e->coding_region_start( $transcript ) + 1;
            }                
            else {
                $coding_bases += $cs - $e->coding_region_start( $transcript );
            }
        }
        return $coding_bases % 3;
    }
    else {
        my $ce = $U5_locus->{chr_start} - 1;
        if ( $transcript->coding_region_start > $ce or $transcript->coding_region_end < $ce ) {
            return -1;
        }
        my $coding_bases = 0;
        for my $e ( @{ $transcript->get_all_Exons } ) {
            next unless $e->coding_region_start( $transcript );
            last if $e->coding_region_end( $transcript ) < $ce;
            if ( $e->seq_region_start > $ce ) {
                $coding_bases += $e->coding_region_end( $transcript ) - $e->coding_region_start( $transcript ) + 1;
            }
            else {
                $coding_bases += $e->coding_region_end( $transcript ) - $ce;
            }            
        }
        return $coding_bases % 3;        
    }    
}

sub target_transcript_for {
    my ( $design ) = @_;    
    
    if ( $design->start_exon_id ) {
        my $transcript = $design->start_exon->transcript->primary_name;
        if ( $transcript and $transcript =~ m/^ENSMUST\d+$/ ) {
            return $transcript;
        }
    }

    try {
        my $transcript = $design->info->target_transcript;
        $transcript->stable_id;
    } catch {
        s/ at .*$//s;
        WARN $_;        
        undef;
    };
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

sub validated_display_features_for {
    my $design = shift;

    my $validated_features = $design->search_related(
        features => {
            'feature_data_type.description' => 'validated'
        },
        {
            join => {
                feature_data => 'feature_data_type'
            }
        }
    );

    my $validated_display_features = $validated_features->search_related(
        display_features => {
            assembly_id => 11,
            label       => 'construct'
        },
        {
            prefetch => [
                {
                   feature => 'feature_type'
                },
                'chromosome',
            ]
        }
    );

    my %display_feature_for;

    while ( my $df = $validated_display_features->next ) {
        my $type = $df->feature->feature_type->description;
        die "Multiple $type features\n" if exists $display_feature_for{$type};        
        $display_feature_for{$type} = $df;
    }

    return \%display_feature_for;
}

__END__
