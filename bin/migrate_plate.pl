#!/usr/bin/env perl

use strict;
use warnings FATAL => 'all';

use LIMS2::REST::Client;
use LIMS2::HTGT::Migrate::Utils qw( format_well_name trim parse_oracle_date canonical_username );
use LIMS2::HTGT::Migrate::Design qw( get_design_data );
use HTGT::DBFactory;
use Log::Log4perl qw( :easy );
use Const::Fast;
use Data::Dump qw( pp );
use Try::Tiny;
use HTTP::Status qw( :constants );
use Getopt::Long;

my ( $htgt, $lims2 );

{
    my %log4perl = (
        level  => $WARN,
        layout => '%d %p %m%n'
    );

    GetOptions(
        'trace'   => sub { $log4perl{level} = $TRACE },
        'debug'   => sub { $log4perl{level} = $DEBUG },
        'verbose' => sub { $log4perl{level} = $INFO },
        'log=s'   => sub { $log4perl{file}  = '>>' . $_[1] },
    ) and @ARGV == 1 or die "Usage: $0 [OPTIONS] PLATE_NAME\n";

    Log::Log4perl->easy_init( \%log4perl );

    $htgt = HTGT::DBFactory->connect( 'eucomm_vector' );

    $lims2 = LIMS2::REST::Client->new();

    my $plate_name = shift @ARGV;

    my $plate = $htgt->resultset( 'Plate' )->find( { name => $plate_name } )
        or die "Failed to retrieve plate $plate_name\n";

    if ( $plate->type eq 'VTP' ) {
        die "Refusing to migrate vector template plate\n";
    }
    
    migrate_plate( $plate );
}

sub migrate_plate {
    my $plate = shift;

    DEBUG( "Migrating plate $plate" );

    my $lims2_plate = retrieve_or_create_lims2_plate( $plate );

    for my $well ( $plate->wells ) {
        migrate_well( $lims2_plate, $well );
    }    
}

sub migrate_well {
    my ( $lims2_plate, $htgt_well ) = @_;

    my $lims2_well = retrieve_lims2_well( $htgt_well );
    if ( defined $lims2_well ) {
        DEBUG( "Well $htgt_well already exists in LIMS2" );
        return $lims2_well;
    }

    # Ensure that the parent well (if any) exists in LIMS2
    my $htgt_parent_well = $htgt_well->parent_well;
    if ( $htgt_parent_well ) {
        migrate_well(
            retrieve_or_create_lims2_plate( $htgt_parent_well->plate ),
            $htgt_parent_well
        );
    }

    my $process_type = process_type_for( $htgt_parent_well, $well );

    DEBUG( "Migrating well $htgt_well, process $process_type" );
    

}

sub lims2_plate_type {
    my $type = shift;

    my $lims2_type = LIMS2::HTGT::Migrate::Utils::lims2_plate_type( $type )
        or die "No corresponding LIMS2 plate type for $type";

    return $lims2_type;
}

const my %HANDLER_FOR_TRANSITION => (
    ROOT => {
        DESIGN => sub { 'create_di' }
    },
    DESIGN => {
        PCS => sub { 'int_recom' },
    },
    PCS => {
        PCS => sub { 'rearray' },
        PGS => \&gateway_2w_or_3w
    },
    PGS => {
        PGS => \&rearray_or_recombinase,
        DNA => sub { 'dna_prep' }
    }
);

sub process_type_for {
    my ( $parent_well, $child_well ) = @_;

    my $parent_type = $parent_well ? lims2_plate_type( $parent_well->plate->type ) : 'ROOT';
    my $child_type  = lims2_plate_type( $child_well->plate->type );

    my $handler = $HANDLER_FOR_TRANSITION{$parent_type}{$child_type}
        or die "No process configured for transition from $parent_type to $child_type";

    return $handler->( $parent_well, $child_well );
}

sub gateway_2w_or_3w {
    die "Not implemented";    
}

sub rearray_or_recombinase {
    die "Not implemented";
}

sub retrieve_or_create_lims2_plate {
    my $plate = shift;

    return retrieve_lims2_plate( $plate ) || create_lims2_plate( $plate );
}

sub retrieve_lims2_plate {
    my $plate = shift;

    my $plate_name = $plate->name;

    my $lims2_plate = try {
        $lims2->GET( 'plate', { name => $plate_name } );
    }
    catch {
        $_->throw() unless $_->not_found;
        undef;
    };

    return $lims2_plate;
}

sub create_lims2_plate {
    my $plate = shift;

    my $plate_data = build_plate_data( $plate );

    my $lims2_plate = $lims2->POST( 'plate', $plate_data );

    return $lims2_plate;
}

sub build_plate_data {
    my $plate = shift;
    
    my %plate_data = (
        name        => $plate->name,
        type        => lims2_plate_type( $plate->type ),
        created_by  => canonical_username( $plate->created_user || 'unknown' ),
        created_at  => parse_oracle_date( $plate->created_date )
    );

    my $desc = trim( $plate->description );
    if ( length $desc ) {
        $plate_data{description} = $desc;
    }    

    for my $c ( $plate->comments ) {
        my $comment_text = trim( $c->plate_comment );
        next unless length $comment_text;
        push @{ $plate_data{comments} }, {
            comment_text => $comment_text,
            created_by   => canonical_username( $c->created_user || 'unknown' ),
            created_at   => parse_oracle_date( $c->created_date )                
        };
    }

    return \%plate_data;
}

sub retrieve_lims2_well {
    my $well = shift;

    my $plate_name = $well->plate->name;
    my $well_name  = $well->well_name;

    my $lims2_well = try {
        $lims2->GET( 'well', { plate_name => $plate_name, well_name => $well_name } );
    }
    catch {
        $_->throw() unless $_->not_found;
        undef;
    };

    return $lims2_well;    
}


