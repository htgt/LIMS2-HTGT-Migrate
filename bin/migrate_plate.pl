#!/usr/bin/env perl

use strict;
use warnings FATAL => 'all';

use LIMS2::REST::Client;
use LIMS2::HTGT::Migrate::Utils qw( trim format_well_name format_bac_library parse_oracle_date canonical_username );
use LIMS2::HTGT::Migrate::Design qw( get_design_data );
use HTGT::DBFactory;
use Log::Log4perl qw( :easy );
use Const::Fast;
use Data::Dump qw( pp );
use Try::Tiny;
use HTTP::Status qw( :constants );
use Getopt::Long;

my ( $htgt, $lims2 );

sub migrate_plate {
    my $plate = shift;

    DEBUG( "Migrating plate $plate" );

    my $lims2_plate = retrieve_or_create_lims2_plate( $plate );

    for my $well ( $plate->wells ) {
        next unless defined $well->design_instance_id; # skip empty wells         
        migrate_well( $lims2_plate, $well );
    }
}

sub migrate_well {
    my ( $lims2_plate, $htgt_well ) = @_;

    # Empty wells have already been excluded from the target plate, we
    # will only encounter an empty well here if it's the parent of a
    # well we're trying to migrate. This means something bad has
    # happened.
    die "Cannot migrate well with null design instance: $htgt_well"
        unless defined $htgt_well->design_instance_id;
    
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

    my $process_type = process_type_for( $htgt_parent_well, $htgt_well );

    my $well_data = build_well_data( $htgt_well, $htgt_parent_well, $process_type );

    # If this is a create_di process, ensure the design exists in
    # LIMS2 before attempting to create the well
    if ( $process_type eq 'create_di' ) {
        retrieve_or_create_lims2_design( $well_data->{process_data}{design_id} );
    }    

    INFO( "Migrating well $htgt_well, process $process_type" );

    # Create the well
    $lims2_well = create_lims2_well( $well_data );

    # XXX TODO: Load assay data (if any)
    
    # Populate accepted_override flag
    my $accepted_data = build_accepted_data( $htgt_well );
    if ( $accepted_data ) {
        $lims2->POST( 'well', 'accepted_override', $accepted_data );
    }

    return $lims2_well;
}

sub gateway_2w_or_3w {
    my ( $parent_well, $child_well ) = @_;

    my ( $cassette, $backbone ) = cassette_backbone_transition( $parent_well, $child_well );
    
    if ( $cassette and not $backbone ) {
        return '2w_gateway';
    }

    if ( $backbone and not $cassette ) {        
        return '2w_gateway';
    }

    if ( $cassette and $backbone ) {
        return '3w_gateway';
    }

    die "Expected gateway process, but $parent_well and $child_well have the same cassette and backbone";    
}

sub rearray_or_recombinase {
    my $well = shift;

    return @{ recombinase_for($well) } > 0 ? 'recombinase' : 'rearray';
}

sub retrieve_or_create_lims2_design {
    my $design_id = shift;

    my $design = try {
        $lims2->GET( 'design', { id => $design_id } );
    }
    catch {
        $_->throw() unless $_->not_found;
        $lims2->POST( 'design', build_design_data( $design_id ) );
    };

    return $design;
}

sub retrieve_or_create_lims2_plate {
    my $plate = shift;

    return retrieve_lims2_plate( $plate ) || create_lims2_plate( build_plate_data($plate) );
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
    my $plate_data = shift;

    my $lims2_plate = $lims2->POST( 'plate', $plate_data );

    return $lims2_plate;
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

sub create_lims2_well {
    my $well_data = shift;

    my $lims2_well = $lims2->POST( 'well', $well_data );

    return $lims2_well;    
}

sub build_design_data {
    my $design_id = shift;

    my $design = $htgt->resultset( 'Design' )->find( { design_id => $design_id } )
        or die "Failed to retrieve design $design_id";
    
    return get_design_data( $design );    
}

sub build_accepted_data {
    my $well = shift;
    
    my $well_data = $well->search_related( well_data => { data_type => 'distribute' } )->first
        or return;

    return {
        plate_name => $well->plate->name,
        well_name  => format_well_name( $well->well_name ),
        created_by => canonical_username( $well_data->edit_user ),
        created_at => parse_oracle_date( $well_data->edit_date ),
        accepted   => $well_data->data_value eq 'yes' ? 1 : 0
    };
}

sub build_plate_data {
    my $plate = shift;
    
    my %plate_data = (
        name        => $plate->name,
        type        => lims2_plate_type( $plate ),
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

sub build_well_data {
    my ( $well, $parent_well, $process_type ) = @_;

    my $plate = $well->plate;
    
    my %well_data = (
        plate_name   => $plate->name,
        well_name    => format_well_name( $well->well_name ),
        created_by   => canonical_username( $plate->created_user || 'unknown' ),
        created_at   => parse_oracle_data( $plate->created_date ),
    );

    my %process_data = (
        input_wells => $parent_well ? [ { plate_name => $parent_well->plate->name, well_name => format_well_name( $parent_well->well_name ) } ]
                    :                 []
    );

    if ( $process_type eq 'create_di' ) {
        $process_data{design_id} = $well->design_instance->design_id;
        $process_data{bacs}      = bacs_for( $well )
    }
    elsif ( $process_type eq 'int_recom' ) {        
        $process_data{cassette} = cassette_for( $well );
        $process_data{backbone} = backbone_for( $well );        
    }
    elsif ( $process_type eq '2w_gateway' ) {
        my ( $cassette, $backbone ) = cassette_backbone_transition( $parent_well, $well );
        if ( $cassette ) {
            $process_data{cassette} = 'cassette';
        }
        else {
            $process_data{backbone} = 'backbone';
        }
        $process_data{recombinase} = recombinase_for($well);
    }
    elsif ( $process_type eq '3w_gateway' ) {
        my ( $cassette, $backbone ) = cassette_backbone_transition( $parent_well, $well );
        $process_data{cassette} = $cassette;
        $process_data{backbone} = $backbone;
        $process_data{recombinase} = recombinase_for($well);
    }
    elsif ( $process_type eq 'recombinase' ) {
        $process_data{recombinase} = recombinase_for($well);
    }
    elsif ( $process_type eq 'rearray' ) {
        # no aux data
    }
    elsif ( $process_type eq 'dna_prep' ) {
        # no aux data
    }

    $well_data{process_data} = \%process_data;

    return \%well_data;
}

sub cassette_backbone_transition {
    my ( $parent_well, $child_well ) = @_;

    my $parent_cassette = cassette_for( $parent_well )
        or die "Failed to determine cassette for $parent_well";
    
    my $parent_backbone = backbone_for( $parent_well )
        or die "Failed to determine backbone for $parent_well";

    my $child_cassette = casette_for( $child_well )
        or die "Failed to determine cassette for $child_well";

    my $child_backbone = backbone_for( $child_well )
        or die "Failed to determine backbone for $child_well";
    
    if ( $parent_cassette eq $child_cassette and $parent_backbone ne $child_backbone ) {
        return ( undef, $child_backbone );
    }

    if ( $parent_cassette ne $child_cassette and $parent_backbone eq $child_backbone ) {
        return ( $child_cassette, undef );
    }

    if ( $parent_cassette ne $child_cassette and $parent_backbone ne $child_backbone ) {
        return ( $child_cassette, $child_backbone );
    }

    return (undef, undef);
}

sub bacs_for {
    my $well = shift;

    die "BACs only applicable to design well"
        unless $well->plate->type eq 'DESIGN';

    my @bacs;

    for my $di_bac ( $well->design_instance->design_instance_bacs ) {
        next unless defined $di_bac->bac_plate;        
        my $bac = $di_bac->bac;
        push @bacs, {
            bac_plate   => substr( $di_bac->bac_plate, -1 ),
            bac_name    => trim( $bac->remote_clone_id ),
            bac_library => format_bac_library( $bac->clone_lib->library )
        }
    }

    return \@bacs;
}

sub lims2_plate_type {
    my $plate = shift;

    if ( $plate->type eq 'DESIGN' ) {
        return 'DESIGN';
    }

    if ( $plate->type eq 'PC' or $plate->type eq 'PCS' ) {
        return 'INT';
    }

    if ( ( $plate->plate_data_value( 'final_vectors' ) || 'no' ) eq 'yes' ) {
        return 'FINAL';
    }

    if ( $plate->type eq 'GR' or $plate->type eq 'GRD' or $plate->type eq 'PGD' ) {
        return 'POSTINT';
    }

    if ( $plate->type eq 'GRQ' or $plate->type eq 'PGG' ) {
        return 'DNA';
    }

    die "Cannot determine LIMS2 plate type for $plate";
}

{
    
    const my %HANDLER_FOR_TRANSITION => (
        ROOT => {
            DESIGN  => sub { 'create_di' }
        },
        DESIGN => {
            INT     => sub { 'int_recom' },
        },
        INT => {
            INT     => sub { 'rearray' },
            POSTINT => \&gateway_2w_or_3w,
            FINAL   => \&gateway_2w_or_3w
        },
        FINAL => {
            FINAL   => \&rearray_or_recombinase,
            DNA     => sub { 'dna_prep' }
        },
        DNA => {
            EP => sub { 'electroporation' }
        },
        EP => {
            ESCLONE  => sub { 'colony_pick' }, # EPD in HTGT
            ESCLONEP => sub { 'colony_pool' },
        },
        ESCLONE => {
            FP => sub { 'freeze' }
        },
        ESCLONEP => {
            ESCLONEX => sub { 'recombinase' }, # Flp excision            
        },
        ESCLONEX => {
            FP => sub { 'freeze' },
            EP2 => sub { 'electroporation' }
        },
        EP2 => {
            ESCLONE2  => sub { 'colony_pick' },
            ESCLONEP2 => sub { 'colony_pool' },
        },
        ESCLONE2 => {
            FP => sub { 'freeze' }
        },
        ESCLONEP2 => {
            FP => sub { 'freeze' }
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
}

{

    const my $DEFAULT_CASSETTE => 'pR6K_R1R2_ZP';

    sub cassette_for {
        my $well = shift;
        
        my $plate_type = lims2_plate_type( $well->plate->type );
        
        if ( $plate_type eq 'DESIGN' ) {
            return;
        }
        
        my $cassette = $well->well_data_value( 'cassette' );
        if ( $cassette ) {
            return $cassette;
        }

        if ( $plate_type eq 'INT' ) {
            return $DEFAULT_CASSETTE;
        }

        if ( $well->parent_well_id ) {
            return cassette_for( $well->parent_well );
        }
    
        return;    
    }
}

{
    const my $DEFAULT_BACKBONE => 'R3R4_pBR_DTA+_Bsd_amp';

    sub backbone_for {
        my $well = shift;

        my $plate_type = lims2_plate_type( $well->plate->type );
        if ( $plate_type eq 'DESIGN' ) {
            return;
        }

        my $backbone = $well->well_data_value( 'backbone' );
        if ( $backbone ) {
            return $backbone;
        }

        if ( $plate_type eq 'INT' ) {
            return $DEFAULT_BACKBONE;
        }

        if ( $well->parent_well_id ) {
            return backbone_for( $well->parent_well );
        }

        return;
    }    
}

sub recombinase_for {
    my $well = shift;

    my %data = map { $_->data_type => $_->data_value } $well->plate->plate_data, $well->well_data;

    return [ grep { $data{$_} } qw( apply_cre apply_flp apply_dre ) ];
}

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

