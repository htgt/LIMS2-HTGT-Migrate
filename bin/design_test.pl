#!/usr/bin/env perl

use strict;
use warnings FATAL => 'all';

use HTGT::DBFactory;
use Log::Log4perl ':easy';
use List::MoreUtils qw( uniq none );
use Getopt::Long;
use Try::Tiny;
use Smart::Comments;
use Perl6::Slurp;
use Const::Fast;
use LIMS2::HTGT::Migrate::Design qw( get_design_data get_target_region_slice
                                     get_target_gene get_target_transcript
                                  );

const my @OLIGO_NAMES => qw( G5 U5 U3 D5 D3 G3 );

my $schema = HTGT::DBFactory->connect('eucomm_vector');

GetOptions( 'id=i' => \my $design_id );

Log::Log4perl->easy_init( { level => $DEBUG, layout => '%p %x %m%n' } );

if ( $design_id ) {
    Log::Log4perl::NDC->push( $design_id );
    my $design = $schema->resultset('Design')->find( { design_id => $design_id } );
    try{
        design_check( $design );
    }
    catch {
        DEBUG( $_ );
    };
}
else {
    my @wells = slurp( $ARGV[0] ); 

    for my $well ( @wells ) {
        check_well_design( $well );
    }

    INFO( 'DONE!!' );
}

sub check_well_design {
    my $well = shift;

    my ( $plate_name, $well_name ) = split /\s/, $well;

    my $wells = $schema->resultset('Well')->search(
        {
            well_name    => $well_name,
            'plate.name' => $plate_name
        },
        {
            join => 'plate'
        }
    );

    if ( $wells->count == 1 ) {
        my $well = $wells->first;
        my $design = $well->design_instance->design;
        Log::Log4perl::NDC->push( $design->design_id );
        try{
            design_check( $design );
        }
        catch{
            DEBUG( $_ );
        };
    }
    else {
        ERROR("Can't find well $plate_name $well_name");
    }

    Log::Log4perl::NDC->remove;
}

sub design_check {
    my $design = shift;

    my $type = type_for( $design );
    my $info = $design->info;
    my $target_slice = get_target_region_slice( $design );

    check_design_comments( $design );
    check_target_region( $design ); # or die
    check_features( $info, $type ); # or die

    my $genes = check_genes_on_slice( $target_slice ); # or die

    my $exons = check_exons( $target_slice );
    unless( $exons ) {
        check_introns( $target_slice );
        return;
    }

    check_coding_exons_and_transcripts( $target_slice ); # or die

    if ( scalar( @{ $genes } ) == 1 ) {
        WARN('All checks pass up to this point, only targetting one gene, unclear why failing '
             . $genes->[0]->stable_id );
    }
    else{
        check_multi_gene( $info, $genes );
    }

    check_target_gene( $design );
    check_transcript( $design );
}

sub check_design_comments{
    my $design = shift;

    my @comments = $design->design_user_comments;
    for my $comment ( @comments ) {
        INFO( 'COMMENT ' . $comment->category->category_name . ': ' . $comment->design_comment );
    }
}

sub check_features {
    my ( $info, $design_type ) = @_;

    my @oligos;

    my $strand = $info->chr_strand;
    my $features = $info->features;

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
                    assembly   => 'GRCm38',
                    chr_name   => $oligo->chromosome->name,
                    chr_start  => $oligo->feature_start,
                    chr_end    => $oligo->feature_end,
                    chr_strand => $oligo->feature_strand
                }
            ]
        };
    }

    if ( $strand == 1 ) {
        if ( $features->{G5}->feature_start > $features->{G3}->feature_start ) {
            LOGDIE( 'G5 oligo after G3 oligo on +ve strand' );
        }
    }
    else {
        if ( $features->{G3}->feature_start > $features->{G5}->feature_start ) {
            LOGDIE( 'G3 oligo after G5 oligo on -ve strand' );
        }
    }

    sanity_check_oligos( $design_type, \@oligos );
}

sub sanity_check_oligos {
    my ( $design_type, $oligos ) = @_;

    LOGDIE("Design has no validated oligos with GRCm38 locus")
        unless @{$oligos} > 1;
    
    my %loci = map { $_->{type} => $_->{loci}[0] } @{$oligos};

    my @chromosomes = uniq map { $_->{chr_name} } values %loci;
    LOGDIE("Oligos have inconsistent chromosome") unless @chromosomes == 1;

    my @strands = uniq map { $_->{chr_strand} } values %loci;
    LOGDIE("Oligos have inconsistent strand") unless @strands == 1;

    my @oligo_names = $strands[0] eq 1 ? @OLIGO_NAMES : reverse @OLIGO_NAMES;

    if ( $design_type eq 'insertion' or $design_type eq 'deletion' ) {
        @oligo_names = grep { $_ ne 'U3' and $_ ne 'D5' } @oligo_names;
    }

    for my $o ( @oligo_names ) {
        my $locus = $loci{$o};
        LOGDIE("Expected oligo oligo $o has no locus")
            unless $locus;
        LOGDIE("Oligo $o has end before start")
            unless $locus->{chr_end} > $locus->{chr_start};
    }

    for my $ix ( 0 .. (@oligo_names - 2) ) {
        my $o1 = $oligo_names[$ix];
        my $o2 = $oligo_names[$ix+1];
        LOGDIE("Oligos $o1 and $o2 in unexpected order")
            unless $loci{$o1}{chr_end} <= $loci{$o2}{chr_start};
    }
}

sub check_target_region{
    my $design = shift;

    my $target_slice = get_target_region_slice( $design );

    my %data;
    for my $datum ( qw( start end length seq_region_name strand ) ) {
        INFO( $datum . ':' . $target_slice->$datum );
        $data{$datum} = $target_slice->$datum;
    }

    if ( $target_slice->length > 10000 ) {
        LOGDIE( "Target Region length too big: " . $target_slice->length );
    }
}

sub check_genes_on_slice{
    my $target_slice = shift;

    my @genes = @{ $target_slice->get_all_Genes };
    
    if ( @genes ) {
        my @gene_ids = map{ $_->stable_id } @genes;
        INFO( 'Genes on target slice: ' . join('  ', @gene_ids) );
        return \@genes;
    }
    else {
        LOGDIE("No genes found in target slice");
    }
}

sub check_exons {
    my $target_slice = shift;

    my $exons = $target_slice->get_all_Exons;
    unless ( @{ $exons } ) {
        WARN('No exons found in target region');
        return;
    }

    for my $e ( @{ $exons } ) {
        INFO( 'Exon on target slice: ' . $e->stable_id );
    }

    return 1;
}

sub check_introns {
    my $target_slice = shift;

    my $transcripts = $target_slice->get_all_Transcripts;
    unless ( @{ $transcripts } ) {
        # NOTE should never happen, we know there is a gene on this slice and no exons, therefore must be introns
        LOGDIE('No transcripts found in target region either : IF YOU ARE SEEING THIS MESSAGE SOMETHING IS VERY WRONG');
    }

    for my $tran ( @{ $transcripts } ) {
        Log::Log4perl::NDC->push( $tran->stable_id );
        my @introns = @{ $tran->get_all_Introns };
        INFO( 'Transcript overlapping target region belongs to gene ' . $tran->get_Gene->stable_id );

        for my $intron ( @introns ) {
            if ( $intron->seq_region_start <= $target_slice->start && $intron->seq_region_end >= $target_slice->start ) {
                INFO( 'Has intron within target region' );
            }
            elsif ( $intron->seq_region_start <= $target_slice->end && $intron->seq_region_end >= $target_slice->end ) {
                INFO( 'Has intron within target region' );
            }
            elsif ( $intron->seq_region_start >= $target_slice->start && $intron->seq_region_end <= $target_slice->end ) {
                INFO( 'Has intron within target region' );
            }
        }

        Log::Log4perl::NDC->pop;
    }
}

sub check_coding_exons_and_transcripts {
    my $target_slice = shift;

    my @transcripts = @{ $target_slice->get_all_Transcripts };

    my $coding_transcript;
    for my $tran ( @transcripts ) {
        if ( $tran->translation ) {
            INFO( 'Transcript ' . $tran->stable_id . ' is coding' );
            $coding_transcript = 1;
        }
        else {
            DEBUG( 'Transcript ' . $tran->stable_id . ' is NON coding' );
        }
    }
    WARN('Target region has no coding transcripts overlapping it')
        unless $coding_transcript;

    my @exons = @{ $target_slice->get_all_Exons };

    my $coding_exons;
    for my $tran ( @transcripts ) {
        my @transcript_exons = map{ $_->stable_id } @{ $tran->get_all_Exons };

        for my $exon ( @exons ) {
            next if none { $_ eq $exon->stable_id } @transcript_exons;

            my $coding_start = try{ $exon->cdna_coding_start( $tran ) };
            if ( $coding_start ) {
                INFO( 'Exon ' . $exon->stable_id
                      . ' has cdna coding region ( on transcript ' . $tran->stable_id . ' )' );
                $coding_exons = 1;
            }
            else {
                DEBUG( 'Exon ' . $exon->stable_id . ' is NON coding ( on transcript ' . $tran->stable_id . ' )' );
            }
        }
    }

    LOGDIE('Exon(s) in target region are non coding')
        unless $coding_exons;
}

sub check_multi_gene {
    my ( $info, $genes ) = @_;

    my $strand = $info->chr_strand;
    
    my @genes_on_strand = map{ $_->stable_id } grep{ $_->strand == 1 } @{ $genes };
    
    if ( scalar( @genes_on_strand ) == 1 ) {
        WARN( "Only one gene on expected design strand $strand " . $genes_on_strand[0] . ' unable to work our error in phase calculation' );
    }
    elsif ( scalar( @genes_on_strand ) > 1 ) {
        WARN( "Multiple possible targets for design on strand $strand " . join(' ', @genes_on_strand) );
    }
    else {
        WARN( "No genes on expected design strand $strand unable to work our error in phase calculation" );
    }
}

sub check_build_gene {
    my $info  = shift;

    try {
        my $build_gene = $info->build_gene;
        INFO( 'Got build gene: ' . $build_gene->stable_id );
    }
    catch {
        s/ at .*$//s;
        LOGDIE( 'Error getting build gene: ' . $_ );
    };
}

sub check_target_gene {
    my $design= shift;

    try {
        my $gene = get_target_gene( $design );
        INFO( 'Got target gene: ' . $gene->stable_id );
    }
    catch {
        s/ at .*$//s;
        LOGDIE( 'Error getting target gene: ' . $_ );
    };

}

sub check_transcript{
    my $design= shift;

    try {
        my $transcript = get_target_transcript( $design );
        INFO( 'Got target transcript: ' . $transcript->stable_id );
    }
    catch {
        s/ at .*$//s;
        LOGDIE( 'Error getting target transcript: ' . $_ );
    };
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
