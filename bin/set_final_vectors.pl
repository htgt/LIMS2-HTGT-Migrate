#!/usr/bin/env perl

use strict;
use warnings FATAL => 'all';

use HTGT::DBFactory;
use Log::Log4perl qw( :easy );
use Try::Tiny;
use Getopt::Long;

use Smart::Comments;

my %log4perl = (
    level  => $WARN,
    layout => '%d %p %x %m%n'
);

GetOptions(
    'trace'   => sub { $log4perl{level} = $TRACE },
    'debug'   => sub { $log4perl{level} = $DEBUG },
    'verbose' => sub { $log4perl{level} = $INFO },
    'plate=s' => \my $plate_name,
    'commit'  => \my $commit,
);

Log::Log4perl->easy_init( \%log4perl );

die ( 'Need plate name' ) unless $plate_name;

my $htgt = HTGT::DBFactory->connect( 'eucomm_vector' );

my $plate = $htgt->resultset( 'Plate' )->find( { name => $plate_name } );
if ( ! $plate ) {
    ERROR( "Failed to retrieve plate $plate_name" );
    next;
}

for my $well ( $plate->wells->all ) {
    Log::Log4perl::NDC->remove;
    Log::Log4perl::NDC->push( "$well" );
    my $parent_well = $well->parent_well;
    next unless $parent_well;

    my $parent_plate = $parent_well->plate;
    DEBUG( "Has parent well $parent_well" );

    set_final_vectors( $parent_plate );
}

unless ( $commit ) {
    WARN('Commit flag not set so NOTHING has been updated');
}

sub set_final_vectors {
    my $plate = shift;

    my $current_final_vectors = $plate->plate_data_value( 'final_vectors' );

    if ( $current_final_vectors && $current_final_vectors eq 'yes' ) {
        INFO( "Plate $plate already has final_vectors value of yes" );
        return;
    }

    my $current_final_picks = $plate->plate_data_value( 'final_picks' );
    if ( $current_final_picks && $current_final_picks eq 'yes' ) {
        INFO( "Plate $plate already has final_picks value of yes" );
        return;
    }

    if ( $commit ) {
        $plate->related_resultset('plate_data')->create(
            {
                data_value => 'yes',
                data_type  => 'final_vectors', 
            } 
        );
        INFO( "Plate $plate updated with final_vectors value" );
    }
    else {
        INFO( "Plate $plate will be updated with final_vectors value" );
    }

}
