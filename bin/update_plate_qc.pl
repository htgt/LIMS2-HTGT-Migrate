#!/usr/bin/env perl

use strict;
use warnings FATAL => 'all';

use LIMS2::REST::Client;
use LIMS2::HTGT::Migrate::Utils qw( canonical_datetime canonical_username );
use HTGT::DBFactory;
use Iterator::Simple qw( iter imap );
use Log::Log4perl qw( :easy );
use Const::Fast;
use Try::Tiny;
use HTTP::Status qw( :constants );
use Getopt::Long;

const my $WELL_DATA_TYPE => 'qc_sequencing_result';

my ( $htgt, $lims2, $qc_schema );

sub update_plate_qc {
    my $plate = shift;

    INFO( "Updating plate qc $plate" );

    my ( $attempted, $updated ) = ( 0, 0 );

    my $lims2_plate = try {
        retrieve_lims2_plate( $plate )
    }
    catch {
        ERROR('Unable to retrieve lims2 plate' . $_);
    };

    return unless $lims2_plate;

    for my $htgt_well ( $plate->wells ) {
        next unless defined $htgt_well->design_instance_id; # skip empty wells
        DEBUG( "Looking at $htgt_well" );

        my $htgt_well_qc = get_htgt_well_qc( $htgt_well );
        next unless $htgt_well_qc;

        my $lims2_well = retrieve_lims2_well( $htgt_well );
        next unless $lims2_well;

        $attempted++;
        Log::Log4perl::NDC->push( $htgt_well->well_name );
        try {
            update_well_qc( $lims2_well, $htgt_well, $htgt_well_qc );
            $updated++;
        }
        catch {
            ERROR( $_ );
        };
        Log::Log4perl::NDC->pop;
    }

    DEBUG( "Successfully updated $updated of $attempted wells" );

    return ( $attempted, $updated );
}

sub update_well_qc {
    my ( $lims2_well, $htgt_well, $htgt_well_qc ) = @_;

    DEBUG( "Updating sequencing Qc for well $htgt_well" );

    my $lims2_well_qc = get_lims2_well_qc( $lims2_well );

    if ( !$lims2_well_qc->{test_result_url} ) {
        create_lims2_well_assay( $htgt_well_qc, $lims2_well );
    }
    elsif ( $htgt_well_qc->{test_result_url} ne $lims2_well_qc->{test_result_url} ) {
        update_lims2_well_assay( $htgt_well_qc, $lims2_well );
    }
    else {
        DEBUG( "Qc results match for $htgt_well, no action required" );
    }

    return $lims2_well;
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

sub get_htgt_well_qc {
    my ( $htgt_well ) = @_;

    my $assay;
    my %well_data = map { $_->data_type => $_ } $htgt_well->well_data;

    if ( $well_data{'new_qc_test_result_id'} ) {
        $assay = get_new_qc_assay( $htgt_well, \%well_data );
    }
    elsif ( $well_data{'qctest_result_id'} ) {
        $assay = get_old_qc_assay( $htgt_well, \%well_data );
    }
    else {
        return;
    }

    return $assay;
}

sub get_lims2_well_qc {
    my ( $lims2_well ) = @_;

    my $lims2_well_qc = try {
        $lims2->GET( 'well', $WELL_DATA_TYPE, { id => $lims2_well->{id} } )
    }
    catch {
        $_->throw() unless $_->not_found;
        undef;
    };

    return $lims2_well_qc;
}

sub update_lims2_well_assay {
    my ( $htgt_well_qc, $lims2_well ) = @_;

    delete_lims2_well_assay( $lims2_well );
    create_lims2_well_assay( $htgt_well_qc, $lims2_well );
}

sub delete_lims2_well_assay {
    my ( $lims2_well ) = @_;

    INFO( "Deleting well assay $WELL_DATA_TYPE for well $lims2_well->{plate_name}\[$lims2_well->{well_name}\]" );
    $lims2->DELETE( 'well', $WELL_DATA_TYPE, { id => $lims2_well->{id} } );
}

sub create_lims2_well_assay {
    my ( $htgt_well_qc, $lims2_well ) = @_;

    $htgt_well_qc->{well_id} = $lims2_well->{id};
    INFO( "Creating well assay $WELL_DATA_TYPE for well $lims2_well->{plate_name}\[$lims2_well->{well_name}\]" );
    my $lims2_assay = $lims2->POST( 'well', $WELL_DATA_TYPE, $htgt_well_qc );

    return $lims2_assay;
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
    ) or die "Usage: $0 [OPTIONS] [PLATE_NAME ...]\n";

    Log::Log4perl->easy_init( \%log4perl );

    $htgt = HTGT::DBFactory->connect( 'eucomm_vector' );

    $qc_schema = HTGT::DBFactory->connect( 'vector_qc' );

    $lims2 = LIMS2::REST::Client->new_with_config();

    my $todo = @ARGV ? iter( \@ARGV ) : imap { chomp; $_ } iter( \*STDIN );

    my ( $total_attempted, $total_updated ) = ( 0, 0 );

    while ( my $plate_name = $todo->next ) {
        Log::Log4perl::NDC->push( $plate_name );
        my $plate = $htgt->resultset( 'Plate' )->find( { name => $plate_name } );
        if ( ! $plate ) {
            ERROR( "Failed to retrieve plate $plate_name" );
            next;
        }
        my ( $attempted, $updated ) = update_plate_qc( $plate );
        $total_attempted += $attempted;
        $total_updated   += $updated;
    }
    continue {
        Log::Log4perl::NDC->pop;
    }

    INFO( "Successfully updated $total_updated of $total_attempted wells" );
}
