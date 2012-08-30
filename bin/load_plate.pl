#!/usr/bin/env perl

use strict;
use warnings FATAL => 'all';

use LIMS2::REST::Client;
use LIMS2::Util::YAMLIterator;
use Log::Log4perl qw( :easy );
use Try::Tiny;
use HTTP::Status qw( :constants );
use Getopt::Long;

my $lims2;

{    
    my %log4perl = (
        level  => $WARN,        
        layout => '%d %p %x %m%n'
    );
    
    GetOptions(
        'verbose' => sub { $log4perl{level} = $INFO },
        'log=s'   => sub { $log4perl{file}  = '>>' . $_[1] },
    ) and @ARGV == 1
        or die "Usage: $0 [OPTIONS] plate.yaml\n";

    Log::Log4perl->easy_init( \%log4perl );

    my $input_file = $ARGV[0];

    $lims2 = LIMS2::REST::Client->new_with_config();

    my $it = iyaml( $input_file );
    while ( my $datum = $it->next ) {
        try {
            create_plate( $datum );
        }
        catch {
            ERROR($_);
        };
    }
}

sub create_plate {
    my $plate_data = shift;
    my $plate_name = $plate_data->{name};
    Log::Log4perl::NDC->pop;
    Log::Log4perl::NDC->push( $plate_name );
    INFO( "Creating plate $plate_name" );

    my $lims2_plate = try {
        retrieve_lims2_plate( $plate_name )
    };
    die("plate already exists in lims2: " . $plate_name) if $lims2_plate;

    $lims2->POST( 'plate', $plate_data );

    INFO( "Successfully created $plate_name plate in lims2" );
}

sub retrieve_lims2_plate {
    my $plate_name = shift;

    my $lims2_plate = try {
        $lims2->GET( 'plate', { name => $plate_name } );
    }
    catch {
        $_->throw() unless $_->not_found;
        undef;
    };

    return $lims2_plate;
}
