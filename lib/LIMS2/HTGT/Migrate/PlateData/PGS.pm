package LIMS2::HTGT::Migrate::PlateData::PGS;

use Moose;
use Const::Fast;
use namespace::autoclean;

const my $IS_SEQUENCING_QC_PASS_PROMOTER =>
    map { $_ => 1 } qw(
        pass
        pass1
        pass2
        pass2.1
        pass2.2
        pass2.3
        pass3
        pass4
        pass4.1
        pass4.3
        pass5.2
        passa
        pass1a
        pass2a
        pass2.1a
        pass2.2a
        pass2.3a
        pass3a
        pass4a
        pass4.1a
        pass4.3a
        pass5.2a
        passb
        pass1b
        pass2b
        pass2.1b
        pass2.2b
        pass2.3b
        pass3b
        pass4b
        pass4.1b
        pass4.3b
        pass5.2b
    );

const my $IS_SEQUENCING_QC_PASS_PROMOTERLESS =>
    map { $_ => 1 } qw(
        pass
        passa
        pass1a
        pass2a
        pass2.1a
        pass2.2a
        pass2.3a
        pass3a
        pass4a
        pass4.1a
        pass4.3a
        pass5.2a
    );

const my $IS_SEQUENCING_QC_PASS_DELETION =>
    map { $_ => 1 } qw(
        pass
        pass1
        pass2
        pass2.1
        pass2.2
        pass2.3
        pass3
        pass4
        pass4.1
        pass4.3
        pass5.2    
    );

extends 'LIMS2::HTGT::Migrate::PlateData';

has '+plate_type' => (
    default => 'pgs'
);

override well_data => sub {
    my ( $self, $well ) = @_;

    my $data = super();

    $data->{cassette}   = $self->get_htgt_well_data_value( 'cassette' );    
    $data->{backbone}   = $self->get_htgt_well_data_value( 'backbone' );
    $data->{clone_name} = $self->get_htgt_well_data_value( 'clone_name' );

    if ( my $legacy_qc_data = $self->get_legacy_qc_data( $well ) ) {
        $self->merge_well_data( $data, $legacy_qc_data );
    }

    if ( my $qc_data = $self->get_qc_data( $well ) ) {
        $self->merge_well_data( $data, $qc_data );
    }

    if ( my $dna_data = $self->get_dna_data( $well ) ) {
        $self->merge_well_data( $data, $dna_data );
    }
    
    return $data;
};

sub get_dna_data {
    my ( $self, $well ) = @_;

    
    
}

sub sequencing_qc_pass_fail {
    my ( $self, $well ) = @_;

    my $pass_level = $self->get_htgt_well_data_value( 'pass_level' ) || 'fail';

    my $design_type = $well->design_instance->design->design_type || 'KO';
    if ( $design_type =~ /^Del/ ) {
        if ( exists $IS_SEQUENCING_QC_PASS_DELETION{ $pass_level } ) {
            return 'pass';
        }
        return 'fail';
    }

    my $cassette = $self->get_htgt_well_data_value( 'cassette' );
    unless ( defined $cassette ) {
        $self->log->error( "well $well has no cassette" );
        return 'fail';
    }

    if ( $cassette =~ /[gs]t.$/ ) {
        if ( exists $IS_SEQUENCING_QC_PASS_PROMOTERLESS{ $pass_level } ) {
            return 'pass';
        }
        return 'fail';
    }

    if ( exists $IS_SEQUENCING_QC_PASS_PROMOTER{ $pass_level } ) {
        return 'pass';
    }

    return 'fail';
}

__PACKAGE__->meta->make_immutable;

1;

__END__
