#!/usr/bin/env perl
use strict;
use warnings FATAL => 'all';

use HTGT::DBFactory;
use YAML::Any;
use Log::Log4perl qw( :easy );
use Try::Tiny;
use Const::Fast;
use LIMS2::HTGT::Migrate::Utils qw( parse_oracle_date );
use List::MoreUtils qw( firstval );

Log::Log4perl->easy_init(
    {
        level  => $WARN,
        layout => '%p %x %m%n'
    }
);

const my @ALIGNMENT_FIELDS => qw(
qc_seq_read_id
primer_name
query_start
query_end
query_strand
target_start
target_end
target_strand
op_str
score
pass
features
cigar
);

const my @ALIGN_REGION_FIELDS => qw(
name
length
match_count
query_str
target_str
match_str
pass
);

my $schema = HTGT::DBFactory->connect( 'eucomm_vector' );

my $qc_rs;
if ( @ARGV ) {
    $qc_rs = $schema->resultset( 'QCRun' )->search( { qc_run_id => \@ARGV } );
}
else {
    $qc_rs = $schema->resultset( 'QCRun' )->search( { } );
}

while ( my $qc_run = $qc_rs->next ) {
    Log::Log4perl::NDC->push( $qc_run->qc_run_id );

    try {
        my ( $seq_read_ids, $seq_reads ) = get_qc_seq_reads( $qc_run );
        my $qc_run_date    = parse_oracle_date( $qc_run->qc_run_date );
        my $template_plate = $qc_run->template_plate;

        my %qc_run = (
            qc_run_id          => $qc_run->qc_run_id,
            qc_run_date        => $qc_run_date->iso8601,
            sequencing_project => $qc_run->sequencing_project,
            template_plate     => $template_plate->name,
            profile            => $qc_run->profile,
            software_version   => $qc_run->software_version,
            qc_test_results    => get_qc_test_results( $qc_run, $seq_read_ids, $template_plate ),
            qc_seq_reads       => $seq_reads, 
        );
        print YAML::Any::Dump( \%qc_run );
    }
    catch {
        ERROR($_);
    }
    finally {        
        Log::Log4perl::NDC->pop;        
    };    
}

sub get_qc_seq_reads {
    my $qc_run = shift;
    my %seq_read_ids;
    my @seq_reads;

    my $seq_reads_rs = $qc_run->seq_reads;

    while ( my $seq_read = $seq_reads_rs->next ) {
        my %seq_read = (
            qc_seq_read_id => $seq_read->qc_seq_read_id,
            description    => $seq_read->description,
            length         => $seq_read->length,
            seq            => $seq_read->seq,
        );
        $seq_read_ids{ $seq_read->qc_seq_read_id } = 1;
        
        push @seq_reads, \%seq_read;
    }

    return ( \%seq_read_ids, \@seq_reads );
}

sub get_qc_test_results {
    my ( $qc_run, $seq_read_ids, $template_plate ) = @_;
    my @qc_test_results;

    my $qc_test_results_rs = $qc_run->test_results;
    my %template_wells = map { uc( substr( $_->well_name, -3 ) ) => $_ }
        grep { defined $_->design_instance_id } $template_plate->wells;
    my @template_wells = keys %template_wells;

    while ( my $qc_test_result = $qc_test_results_rs->next ) {
        my $template_well = get_template_well( $qc_test_result, \%template_wells );
        push @qc_test_results, {
            well_name     => $qc_test_result->well_name,
            score         => $qc_test_result->score,
            pass          => $qc_test_result->pass,
            plate_name    => $qc_test_result->plate_name,
            template_well => "$template_well",
            alignments    => get_test_result_alignments( $qc_test_result, $seq_read_ids ),
         };
    }
    return \@qc_test_results;
}

sub get_template_well {
    my ( $qc_test_result, $template_wells ) = @_;

    my $design_id = $qc_test_result->synvec->design_id;
    my $well_name = $qc_test_result->well_name;

    # First try for a template well in the same location on the template plate
    my $template_well = $template_wells->{$well_name};
    unless ( $template_well
                and $template_well->design_instance
                    and $template_well->design_instance->design_id == $design_id ) {
        # Fallback to considering any well on the template plate
        $template_well = firstval { $_->design_instance->design_id == $design_id } values %{ $template_wells }
            or die "Failed to retrieve template well for design $design_id\n";
    }

    return $template_well;
}

sub get_test_result_alignments {
    my ( $qc_test_result, $seq_read_ids ) = @_;
    my @test_result_alignments;

    my $alignments_rs = $qc_test_result->alignments;

    while ( my $alignment = $alignments_rs->next ) {
        my %alignment = map { $_ => $alignment->$_ } @ALIGNMENT_FIELDS;

        die( 'unknown seq read: ' . $alignment{qc_seq_read_id} ) 
            unless exists $seq_read_ids->{ $alignment{qc_seq_read_id} };

        $alignment{align_regions} = get_align_regions( $alignment );
        push @test_result_alignments, \%alignment;
    }

    return \@test_result_alignments;
}

sub get_align_regions {
    my $alignment = shift;
    my @align_regions;

    my $align_regions_rs = $alignment->align_regions;

    while ( my $align_region = $align_regions_rs->next ) {
        my %align_region = map{ $_ => $align_region->$_ } @ALIGN_REGION_FIELDS; 
        push @align_regions, \%align_region;
    }

    return \@align_regions;
}

__END__
