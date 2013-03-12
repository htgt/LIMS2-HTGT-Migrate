#!/usr/bin/env perl

use strict;
use warnings FATAL => 'all';

use LIMS2::REST::Client;
use LIMS2::HTGT::Migrate::Utils qw( trim format_well_name format_bac_library canonical_datetime canonical_username );
use LIMS2::HTGT::Migrate::Design qw( get_design_data );
use HTGT::DBFactory;
use Iterator::Simple qw( iter imap );
use Log::Log4perl qw( :easy );
use Const::Fast;
use Data::Dump qw( pp );
use Try::Tiny;
use HTTP::Status qw( :constants );
use Getopt::Long;
use Smart::Comments;

const my @RECOMBINASE => qw( Cre Flp Dre );

my ( $htgt, $lims2, $qc_schema );

sub migrate_plate {
    my ( $plate, $well_name ) = @_;

    DEBUG( "Migrating plate $plate" );

    my ( $attempted, $migrated ) = ( 0, 0 );

    my $lims2_plate = try {
        retrieve_or_create_lims2_plate( $plate )
    }
    catch {
        ERROR('Unable to retrieve or create lims2 plate' . $_);
    };

    return unless $lims2_plate;

    for my $well ( $plate->wells ) {
        next if $well_name && $well_name ne $well->well_name;
        next unless defined $well->design_instance_id; # skip empty wells
        $attempted++;
        Log::Log4perl::NDC->push( $well->well_name );
        try {
            migrate_well( $lims2_plate, $well );
            $migrated++;
        }
        catch {
            ERROR( $_ );
        };
        Log::Log4perl::NDC->pop;
    }

    INFO( "Successfully migrated $migrated of $attempted wells" );

    return ( $attempted, $migrated );
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

    $lims2_well = create_lims2_well( $well_data );

    load_assay_data( $htgt_well, $process_type );
    my $accepted_data = build_accepted_data( $htgt_well );
    if ( $accepted_data ) {
        $lims2->POST( 'well', 'accepted', $accepted_data );
    }
    return $lims2_well;
}

sub compute_process_type {
    my ( @expected_types ) = @_;

    return sub {
        my ( $parent_well, $child_well ) = @_;

        my ( $cassette, $backbone ) = cassette_backbone_transition( $parent_well, $child_well );

        my $process_type;

        if ( $cassette and not $backbone ) {
            $process_type = '2w_gateway';
        }
        elsif ( $backbone and not $cassette ) {
            $process_type = '2w_gateway';
        }
        elsif ( $cassette and $backbone ) {
            $process_type = '3w_gateway';
        }
        elsif ( @{ recombinase_for( $child_well ) } > 0 ) {
            $process_type = 'recombinase';
        }
        else {
            $process_type = 'rearray';
        }

        for my $expected ( @expected_types ) {
            if ( $process_type eq $expected ) {
                return $process_type;
            }
        }

        die "Computed process type $process_type was not one of " . join( q{,}, @expected_types ) . "\n";
    };
}

sub retrieve_or_create_lims2_design {
    my $design_id = shift;

    my $design = try {
        $lims2->GET( 'design', { id => $design_id } );
    }
    catch {
        $_->throw() unless $_->not_found;
        INFO( "Creating design $design_id" );
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

    INFO( "Creating plate $plate_data->{name}, type $plate_data->{type}" );
    my $lims2_plate = $lims2->POST( 'plate', $plate_data );

    return $lims2_plate;
}

sub retrieve_lims2_well {
    my $well = shift;
    my $plate_name = $well->plate->name;
    my $well_name  = format_well_name($well->well_name);
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

    INFO( "Creating well $well_data->{plate_name}\[$well_data->{well_name}\], process type $well_data->{process_data}{type}" );
    my $lims2_well = $lims2->POST( 'well', $well_data );

    return $lims2_well;
}

sub create_lims2_well_assay {
    my ( $type, $assay ) = @_;

    INFO( "Creating well assay $type for well $assay->{plate_name}\[$assay->{well_name}\]" );
    my $lims2_asasy = $lims2->POST( 'well', $type, $assay );

    return $assay;
}

sub build_design_data {
    my $design_id = shift;
    Log::Log4perl::NDC->push( $design_id );

    my $design = $htgt->resultset( 'Design' )->find( { design_id => $design_id } )
        or die "Failed to retrieve design $design_id";

    my $design_data = get_design_data( $design );
    Log::Log4perl::NDC->pop;

    return $design_data;
}

sub build_accepted_data {
    my $well = shift;

    my $well_data = $well->search_related( well_data => { data_type => 'distribute' } )->first
        or return;

    return {
        plate_name => $well->plate->name,
        well_name  => format_well_name( $well->well_name ),
        created_by => canonical_username( $well_data->edit_user || 'unknown' ),
        created_at => canonical_datetime( $well_data->edit_date ),
        accepted   => $well_data->data_value eq 'yes' ? 1 : 0
    };
}

sub build_plate_data {
    my $plate = shift;

    my %plate_data = (
        name        => $plate->name,
        type        => lims2_plate_type( $plate ),
        created_by  => canonical_username( $plate->created_user || 'unknown' ),
        created_at  => canonical_datetime( $plate->created_date ),
        species     => 'Mouse',
    );

    my $desc = trim( $plate->description );
    if ( length $desc ) {
        $plate_data{description} = $desc;
    }

    for my $c ( $plate->plate_comments ) {
        my $comment_text = trim( $c->plate_comment );
        next unless length $comment_text;
        push @{ $plate_data{comments} }, {
            comment_text => $comment_text,
            created_by   => canonical_username( $c->edit_user || 'unknown' ),
            created_at   => canonical_datetime( $c->edit_date )
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
        created_at   => canonical_datetime( $plate->created_date ),
    );

    my %process_data = (
        type        => $process_type,
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
            $process_data{cassette} = $cassette;
        }
        else {
            $process_data{backbone} = $backbone;
        }
        $process_data{recombinase} = recombinase_for($well);
    }
    elsif ( $process_type eq '3w_gateway' ) {
        my ( $cassette, $backbone ) = cassette_backbone_transition( $parent_well, $well );
        $process_data{cassette} = $cassette;
        $process_data{backbone} = $backbone;
        $process_data{recombinase} = recombinase_for($well);
    }
    elsif ( $process_type eq 'legacy_gateway' ) {
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
    elsif ( $process_type eq 'clone_pick' ) {
        # no aux data
    }
    elsif ( $process_type eq 'clone_pool' ) {
        # no aux data
    }
    elsif ( $process_type eq 'freeze' ) {
        #no aux data
    }
    elsif ( $process_type eq 'first_electroporation' ) {
        my $cell_line = $well->well_data_value('es_cell_line') || $well->plate->plate_data_value('es_cell_line');
        die "No es_cell_line set for $well" unless $cell_line;

        $process_data{cell_line} = $cell_line;
    }
    elsif ( $process_type eq 'second_electroporation' ) {
        die "Not implemented SEP plate migrate"
    }
    else {
        die "Un-recognised process type: $process_type";

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

    my $child_cassette = cassette_for( $child_well )
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

    if ( $plate->type eq 'PGD' or $plate->type eq 'GR' ) {
        my @queue = ( $plate );
        while ( @queue ) {
            my $pplate = shift @queue;
            if ( ( $pplate->plate_data_value( 'final_vectors' ) || 'no' ) eq 'yes' ) {
                return 'FINAL';
            }
            elsif ( ( $pplate->plate_data_value( 'final_picks' ) || 'no' ) eq 'yes' ) {
                return 'FINAL_PICK';
            }
            my %parent_plates = map { $_->plate_id => $_ }
                map { $_->parent_well_id ? $_->parent_well->plate : () }
                    $pplate->wells;
            push @queue, grep { $_->type eq 'PGD' or $_->type eq 'GR' } values %parent_plates;
        }
        return 'POSTINT';
    }

    if ( $plate->type eq 'GRD' or $plate->type eq 'PGG' or $plate->type eq 'GRQ' ) {
        return 'DNA';
    }

    if ( $plate->type eq 'EP' ){
        return 'EP';
    }

    if ( $plate->type eq 'EPD' ){
        return 'EP_PICK';
    }

    if ( $plate->type eq 'FP' ){
        return 'FP';
    }
    #NOTE, only migrated plates up to type DNA, the code to migrate other plate types is
    # here but it is untested

    die "Cannot determine LIMS2 plate type for $plate";
}

{

    const my %HANDLER_FOR_TRANSITION => (
        ROOT => {
            DESIGN  => sub { 'create_di' },
        },
        DESIGN => {
            INT     => sub { 'int_recom' },
        },
        INT => {
            INT        => sub { 'rearray' },
            POSTINT    => compute_process_type( qw( 2w_gateway 3w_gateway ) ),
            FINAL      => compute_process_type( qw( 2w_gateway 3w_gateway ) ),
            FINAL_PICK => sub{ 'legacy_gateway' },
        },
        POSTINT => {
            POSTINT => compute_process_type( qw( 2w_gateway recombinase rearray ) ),
            FINAL   => compute_process_type( qw( 2w_gateway recombinase ) ),
        },
        FINAL => {
            FINAL      => compute_process_type( qw( recombinase rearray ) ),
            FINAL_PICK => sub { 'final_pick' },
            DNA        => sub { 'dna_prep' },
        },
        FINAL_PICK => {
            FINAL_PICK => sub { 'final_pick' },
        },
        DNA => {
            DNA => sub { 'rearray' },
            EP => sub { 'first_electroporation' },
        },
        EP => {
            EP => sub { 'rearray' },
            EP_PICK => sub { 'clone_pick' }, # EPD in HTGT
            # NOTE not setup to handle this processes
#            XEP     => sub { 'recombinase' }, # Flp excision
        },
        EP_PICK => {
            EP_PICK => sub { 'rearray'},
            FP => sub { 'freeze' },
        },
        FP => {
            FP => sub { 'rearray' },
        },
        # NOTE not setup to handle processes below yet
        XEP => {
            XEP_POOL => sub { 'clone_pool' },
            XEP_PICK => sub { 'clone_pick' }, # EPD in HTGT
            SEP      => sub { 'second_electroporation' },
        },
        SEP => {
            SEP_PICK => sub { 'clone_pick' },
            SEP_POOL => sub { 'clone_pool' },
        },
        SEP_PICK => {
            SFP => sub { 'freeze' }
        },
    );

    sub process_type_for {
        my ( $parent_well, $child_well ) = @_;

        my $parent_type = $parent_well ? lims2_plate_type( $parent_well->plate ) : 'ROOT';
        my $child_type  = lims2_plate_type( $child_well->plate );

        die "No process configured for transition from $parent_type to $child_type"
            unless exists $HANDLER_FOR_TRANSITION{$parent_type}
                and exists $HANDLER_FOR_TRANSITION{$parent_type}{$child_type};

        return $HANDLER_FOR_TRANSITION{$parent_type}{$child_type}->( $parent_well, $child_well );
    }
}

{

    const my $DEFAULT_CASSETTE => 'pR6K_R1R2_ZP';

    sub cassette_for {
        my $well = shift;

        my $plate_type = lims2_plate_type( $well->plate );

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
    const my $DEFAULT_BACKBONE => 'R3R4_pBR_amp';

    sub backbone_for {
        my $well = shift;

        my $plate_type = lims2_plate_type( $well->plate );
        if ( $plate_type eq 'DESIGN' ) {
            return;
        }

        my $backbone = $well->well_data_value( 'backbone' );
        if ( $backbone ) {
            return $backbone;
        }

        if ( $well->parent_well_id ) {
            my $parent_well = $well->parent_well;
            if ( $plate_type eq 'INT' and $parent_well->plate->type eq 'DESIGN' ) {
                return $DEFAULT_BACKBONE;
            }
            return backbone_for( $parent_well );
        }

        return;
    }
}

sub plate_well_data {
    my $well = shift;

    my %data = map { lc $_->data_type => $_->data_value } $well->plate->plate_data, $well->well_data;

    return \%data;
}

sub recombinase_for {
    my $well = shift;

    my $parent_well = $well->parent_well
        or return []; # Cannot apply recombinase without a parent well

    my $parent_data = plate_well_data( $parent_well );
    my $data        = plate_well_data( $well );

    my @recombinase_for;

    for my $r ( @RECOMBINASE ) {
        my $data_type = 'apply_' . lc $r;
        if ( $data->{$data_type} and not $parent_data->{$data_type} ) {
            push @recombinase_for, $r;
        }
    }

    return \@recombinase_for;
}

{
    my %ASSAY_DATA_HANDLER = (
        DESIGN => [\&load_recombineering_assays,],
        PCS    => [\&load_sequencing_assays,],
        PC     => [\&load_sequencing_assays,],
        PG     => [\&load_sequencing_assays,],
        PGD    => [\&load_sequencing_assays,],
        GR     => [\&load_sequencing_assays,],
        GRQ    => [\&load_sequencing_assays, \&load_dna_assays,],
        GRD    => [\&load_sequencing_assays, \&load_dna_assays,],
        PGG    => [\&load_dna_assays,],
        EP     => [\&load_clone_pick_data,],
        EPD    => [\&load_primer_band_data, \&load_sequencing_assays,],
        #NOTE not setup to handle plates below yet
        REPD   => [\&load_primer_band_data,],
        PIQ    => [\&load_primer_band_data,],
    );

    sub load_assay_data {
        my ( $htgt_well, $process_type ) = @_;

        my $plate_type = $htgt_well->plate->type;

        return unless exists $ASSAY_DATA_HANDLER{$plate_type};

        my %well_data = map { $_->data_type => $_ } $htgt_well->well_data;

        for my $assay_handler ( @{ $ASSAY_DATA_HANDLER{$plate_type} } ){
            $assay_handler->($htgt_well, \%well_data);
        }
        return 1;
    }
}

{
    const my @COLONY_RESULTS => qw(
      BLUE_COLONIES
      COLONIES_PICKED
      WHITE_COLONIES
      TOTAL_COLONIES
      REMAINING_UNSTAINED_COLONIES
    );

    my %MAPPING = (
        COLONIES_PICKED => "picked_colonies",
    );


    sub load_clone_pick_data {
        my ( $htgt_well, $well_data ) = @_;

        for (@COLONY_RESULTS) {
            my $wd = $well_data->{$_};
            next unless $wd;
            my $assay = common_assay_data( $htgt_well, $wd );
            $assay->{colony_count_type} = lc ($MAPPING{ $wd->data_type } or $wd->data_type);
            $assay->{colony_count} = $wd->data_value;
            create_lims2_well_assay( 'colony_picks', $assay );
        }
    }
}

{
    const my @PRIMER_BAND_TYPES => qw(
        gr1
        gr2
        gr3
        gr4
        gf1
        gf2
        gf3
        gf4
        tr_pcr
    );

    sub load_primer_band_data {
        my ( $htgt_well, $well_data ) = @_;

        for my $type ( @PRIMER_BAND_TYPES ) {
            my $wd = $well_data->{'primer_band_' . $type};
            next unless $wd;
            my $assay = common_assay_data( $htgt_well, $wd );
            $assay->{primer_band_type} = $type;
            $assay->{pass} = $wd->data_value eq 'yes' ? 1 : 0;
            create_lims2_well_assay( 'primer_bands', $assay );
        }
    }
}


sub load_recombineering_assays {
    my ( $htgt_well, $well_data ) = @_;

    for my $wd ( map { $well_data->{$_} or () } qw( pcr_u pcr_d pcr_g rec_u rec_d rec_g rec_ns rec-result ) ) {
        ( my $type = lc $wd->data_type ) =~ s/[\s-]+/_/g;
        my $assay = common_assay_data( $htgt_well, $wd );
        $assay->{result_type} = $type;
        $assay->{result} = $wd->data_value;
        create_lims2_well_assay( 'recombineering_result', $assay );
    }
}

sub load_dna_assays {
    my ( $htgt_well, $well_data ) = @_;

    if ( my $dna_status = $well_data->{DNA_STATUS} ) {
        my $assay = common_assay_data( $htgt_well, $dna_status );
        if ( $dna_status->data_value and $dna_status->data_value eq 'pass' ) {
            $assay->{pass} = 1;
        }
        else {
            $assay->{pass} = 0;
        }
        create_lims2_well_assay( 'dna_status', $assay );
    }

    if ( my $dna_quality = $well_data->{DNA_QUALITY} ) {
        my $assay = common_assay_data( $htgt_well, $dna_quality );
        $assay->{quality} = $dna_quality->data_value;
        if ( my $dna_quality_comment = $well_data->{DNA_QUALITY_COMMENTS} ) {
            $assay->{comment_text} = $dna_quality_comment->data_value;
        }
        create_lims2_well_assay( 'dna_quality', $assay );
    }
}

sub load_sequencing_assays {
    my ( $htgt_well, $well_data ) = @_;

    my $assay;

    if ( $well_data->{new_qc_test_result_id} ) {
        $assay = get_new_qc_assay( $htgt_well, $well_data );
    }
    elsif ( $well_data->{qctest_result_id} ) {
        $assay = get_old_qc_assay( $htgt_well, $well_data );
    }
    else {
        return;
    }

    create_lims2_well_assay( 'qc_sequencing_result', $assay );

    return;
}

sub get_new_qc_assay {
    my ( $well, $well_data ) = @_;

    my $tr_well_data = $well_data->{new_qc_test_result_id};

    my $assay = common_assay_data( $well, $tr_well_data );

    my $result_id = $tr_well_data->data_value;

    $assay->{test_result_url} = 'http://www.sanger.ac.uk/htgt/newqc/view_result/' . $result_id;

    if ( $well_data->{valid_primers} and $well_data->{valid_primers}->data_value ) {
        $assay->{valid_primers} = $well_data->{valid_primers}->data_value;
    }

    if ( $well_data->{pass_level} and $well_data->{pass_level}->data_value eq 'pass' ) {
        $assay->{pass} = 1;
    }

    if ( $well_data->{mixed_reads} and $well_data->{mixed_reads}->data_value eq 'yes' ) {
        $assay->{mixed_reads} = 1;
    }

    return $assay;
}

sub get_old_qc_assay {
    my ( $well, $well_data ) = @_;

    my $qctest_well_data = $well_data->{qctest_result_id};

    my $assay = common_assay_data( $well, $qctest_well_data );

    my $qctest_result_id = $qctest_well_data->data_value;

    $assay->{test_result_url} = 'http://www.sanger.ac.uk/htgt/qc/qctest_result_view?qctest_result_id=' . $qctest_result_id;

    # XXX This conversion of pass level to boolean might be too naive
    if ( $well_data->{pass_level} and $well_data->{pass_level}->data_value =~ m/pass/ ) {
        $assay->{pass} = 1;
    }

    my $qctest_result = $qc_schema->resultset( 'QctestResult' )->find(
        {
            qctest_result_id => $qctest_result_id
        }
    ) or return $assay;

    my %valid_primers;

    foreach my $primer ( $qctest_result->qctestPrimers ) {
        my $seq_align_feature = $primer->seqAlignFeature
            or next;
        my $loc_status = $seq_align_feature->loc_status
            or next;
        $valid_primers{ uc( $primer->primer_name ) } = 1
            if $loc_status eq 'ok';
    }

    $assay->{valid_primers} = join q{,}, sort keys %valid_primers;

    return $assay;
}

sub common_assay_data {
    my ( $well, $well_data ) = @_;

    return {
        plate_name  => $well->plate->name,
        well_name   => format_well_name( $well->well_name ),
        created_at  => canonical_datetime( $well_data->edit_date ),
        created_by  => canonical_username( $well_data->edit_user || 'unknown' )
    }
}

{
    my %log4perl = (
        level  => $WARN,
        layout => '%d %p %x %m%n'
    );

    GetOptions(
        'trace'   => sub { $log4perl{level} = $TRACE },
        'debug'   => sub { $log4perl{level} = $DEBUG },
        'verbose' => sub { $log4perl{level} = $INFO },
        'log=s'   => sub { $log4perl{file}  = '>>' . $_[1] },
        'gene_design_list=s' => \my $gene_list,
        'well=s'             => \my $well_name,
    ) or die "Usage: $0 [OPTIONS] [PLATE_NAME ...]\n";

    Log::Log4perl->easy_init( \%log4perl );

    $htgt = HTGT::DBFactory->connect( 'eucomm_vector' );

    $qc_schema = HTGT::DBFactory->connect( 'vector_qc' );

    $lims2 = LIMS2::REST::Client->new_with_config();

    my $todo = @ARGV ? iter( \@ARGV ) : imap { chomp; $_ } iter( \*STDIN );

    my ( $total_attempted, $total_migrated ) = ( 0, 0 );

    while ( my $plate_name = $todo->next ) {
        Log::Log4perl::NDC->push( $plate_name );
        my $plate = $htgt->resultset( 'Plate' )->find( { name => $plate_name } );
        if ( ! $plate ) {
            ERROR( "Failed to retrieve plate $plate_name" );
            next;
        }
        if ( $plate->type eq 'VTP' ) {
            WARN( "Refusing to migrate vector template plate" );
            next;
        }
        my ( $attempted, $migrated ) = migrate_plate( $plate, $well_name );
        $total_attempted += $attempted;
        $total_migrated  += $migrated;
    }
    continue {
        Log::Log4perl::NDC->remove;
    }

    INFO( "Successfully migrated $total_migrated of $total_attempted wells" );
}
