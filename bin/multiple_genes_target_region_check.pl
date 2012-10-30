#!/usr/bin/env perl

use strict;
use warnings FATAL => 'all';

use HTGT::DBFactory;
use Log::Log4perl ':easy';
use List::MoreUtils qw( uniq none );
use Try::Tiny;
use Perl6::Slurp;
use LIMS2::HTGT::Migrate::Design qw( get_target_region_slice );
use IO::File;
use IO::Handle;
use CSV::Writer;

use Smart::Comments;

my $schema = HTGT::DBFactory->connect('eucomm_vector');

Log::Log4perl->easy_init( { level => $DEBUG, layout => '%p %x %m%n' } );

my @multi_gene_data;

my @design_ids = split( "\n", slurp( $ARGV[0] ) );

for my $design_id ( @design_ids ) {
    Log::Log4perl::NDC->push( $design_id );

    my $design = $schema->resultset('Design')->find({ design_id => $design_id });

    try{ check_design( $design ) } catch { ERROR( $_ ) };

    Log::Log4perl::NDC->remove;
}

my $target_genes_file = IO::File->new( 'target_genes.csv',
        O_RDWR | O_CREAT | O_TRUNC, 0644 ) or die "create csv file: $!";

my $project_genes_file = IO::File->new( 'project_genes.csv',
        O_RDWR | O_CREAT | O_TRUNC, 0644 ) or die "create csv file: $!";

my $target_genes_csv = CSV::Writer->new( output => $target_genes_file );
my $project_genes_csv = CSV::Writer->new( output => $project_genes_file );

$target_genes_csv->write( 'design_id', 'ensembl_gene_id', 'marker_symbol','ensembl_gene_id', 'marker_symbol');
$project_genes_csv->write( 'design_id', 'project_ids', 'marker_symbol' );

for my $data ( @multi_gene_data ) {
    $target_genes_csv->write( $data->{design_id}, map{ $_, $data->{target_region_genes}{$_} } keys %{ $data->{target_region_genes} } );

    $project_genes_csv->write( $data->{design_id}, $data->{project_ids}, @{ $data->{project_genes} } );
}

sub check_design {
    my $design = shift;

    my $genes_in_target_region;

    try {
        $genes_in_target_region = get_target_region_genes( $design );
    }
    catch {
        ERROR('Error getting genes in target region: ' . $_);
    };

    if ( scalar( @{ $genes_in_target_region } ) > 1 ) {
        INFO( 'We have multiple genes in target region' );
        store_design_info( $design, $genes_in_target_region );
    }
    else {
        DEBUG('Just one gene in target region');
    }

}

sub store_design_info{
    my ( $design, $genes ) = @_;

    my %data;
    $data{design_id} = $design->design_id;
    my %genes_data = map{ $_->stable_id => $_->external_name } @{ $genes };
    $data{target_region_genes} = \%genes_data;

    my @projects = $design->projects;
    $data{project_ids} = join( '  ', map{ $_->project_id } @projects );

    my @project_genes = uniq map{  $_->mgi_gene->marker_symbol } @projects; 
    $data{project_genes} = \@project_genes;

    push @multi_gene_data, \%data;
}

sub get_target_region_genes {
    my $design = shift;

    my $target_slice = get_target_region_slice( $design );

    if ( $target_slice->length > 10000 ) {
        LOGDIE( "Target Region length too big: " . $target_slice->length );
    }

    my @genes = @{ $target_slice->get_all_Genes };
    
    if ( @genes ) {
        return \@genes;
    }
    else {
        LOGDIE("No genes found in target slice");
    }
}
