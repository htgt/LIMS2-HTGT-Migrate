#!/usr/bin/env perl

use strict;
use warnings FATAL => 'all';

use HTGT::DBFactory;
use YAML::Any;
use DateTime;
use Log::Log4perl qw( :easy );
use Try::Tiny;
use Const::Fast;
use LIMS2::HTGT::Migrate::Utils qw( trim parse_oracle_date );

const my $ASSEMBLY => 'NCBIM37';

const my @WANTED_DESIGN_STATUS => ( 'Ready to order', 'Ordered' );

const my @GENOTYPING_PRIMER_NAMES => qw( GF1 GF2 GF3 GF4
                                         GR1 GR2 GR3 GR4
                                         LF1 LF2 LF3
                                         LR1 LR2 LR3
                                         PNFLR1 PNFLR2 PNFLR3
                                         EX3 EX32 EX5 EX52 );

const my @OLIGO_NAMES => qw( G5 U5 U3 D5 D3 G3 );

Log::Log4perl->easy_init(
    {
        level  => $WARN,
        layout => '%p %x %m%n'
    }
);

my $schema = HTGT::DBFactory->connect( 'eucomm_vector' );

my $run_date = DateTime->now;

my $designs_rs;

if ( @ARGV ) {
    $designs_rs = $schema->resultset( 'Design' )->search( { design_id => \@ARGV } );
}
else {
    $designs_rs = $schema->resultset( 'Design' )->search(
        {
            'statuses.is_current'            => 1,
            'design_status_dict.description' => \@WANTED_DESIGN_STATUS,
            'projects.project_id'            => { '!=', undef },
        },
        {
            join => [ 'projects', { 'statuses' => 'design_status_dict' } ],
            distinct => 1
        }
    );
}

while ( my $design = $designs_rs->next ) {
    Log::Log4perl::NDC->push( $design->design_id );
    try {
        my $type = type_for( $design );
        my $created_date = parse_oracle_date( $design->created_date ) || $run_date;
        my %design = (
            design_id               => $design->design_id,
            design_name             => $design->find_or_create_name,
            design_type             => $type,
            created_by              => $design->created_user || 'migrate_script',
            created_at              => $created_date->iso8601,
            phase                   => phase_for( $design, $type ),
            validated_by_annotation => $design->validated_by_annotation || '',
            oligos                  => oligos_for( $design ),
            genotyping_primers      => genotyping_primers_for( $design ),
            comments                => comments_for( $design, $created_date ),
            target_transcript       => target_transcript_for( $design )
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
    my $design = shift;

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
            design_oligo_type => $oligo_name,
            design_oligo_seq  => $oligo_seq[0]->data_item,
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

    return \@oligos;
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
            genotyping_primer_type => $feature->feature_type->description,
            genotyping_primer_seq  => $primer_seq[0]->data_item
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
            design_comment          => $comment->design_comment,
            design_comment_category => $category,
            created_by              => $comment->edited_user || 'migrate_script',
            created_at              => $created_date->iso8601,
            is_public               => $comment->visibility eq 'public'
        };
    }

    return \@comments;
}

sub type_for {
    my $design = shift;

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
    my ( $design, $type ) = @_;

    my $phase = $design->phase;

    if ( defined $phase ) {
        return $phase;
    }

    if ( $design->start_exon and $type ne 'artificial-intron' ) {
        return $design->start_exon->phase;
    }

    die "Unable to determine phase for design " . $design->design_id . "\n";
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
        ERROR $_;
        undef;
    };
}

__END__
