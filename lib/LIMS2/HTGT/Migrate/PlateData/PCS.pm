package LIMS2::HTGT::Migrate::PlateData::PCS;

use Moose;
use LIMS2::HTGT::Migrate::Utils;
use Const::Fast;
use namespace::autoclean;

const my $DEFAULT_BACKBONE => 'R3R4_pBR_DTA+_Bsd_amp';
const my $DEFAULT_CASSETTE => 'pR6K_R1R2_ZP';

const my %IS_SEQUENCING_QC_PASS => map { $_ => 1 } qw(                                                         
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
);

extends 'LIMS2::HTGT::Migrate::PlateData';

has '+plate_type' => (
    default => 'pcs'
);

override well_data => sub {
    my ( $self, $well ) = @_;

    my $data = super();

    $data->{cassette}   = $self->get_htgt_well_data_value( 'cassette' ) || $DEFAULT_CASSETTE;    
    $data->{backbone}   = $self->get_htgt_well_data_value( 'backbone' ) || $DEFAULT_BACKBONE;
    $data->{clone_name} = $self->get_htgt_well_data_value( 'clone_name' );

    my $first_qc_date = $self->get_htgt_plate_data_value( 'first_qc_date' );
    if ( $first_qc_date ) {
        $data->{assay_pending} = $self->parse_oracle_date( $first_qc_date )->iso8601;
    }

    my $qc_done = $self->get_htgt_plate_data( 'qc_done' );
    if ( $qc_done ) {
        $data->{assay_complete} = $self->parse_oracle_date( $qc_done->edit_date )->iso8601;
    }

    if ( my $legacy_qc_data = $self->get_legacy_qc_data( $well ) ) {
        $self->merge_well_data( $data, $legacy_qc_data );
    }

    if ( my $qc_data = $self->get_qc_data( $well ) ) {
        $self->merge_well_data( $data, $qc_data );
    }
    
    return $data;
};

sub sequencing_qc_pass_fail {
    my ( $self, $well ) = @_;

    my $pass_level = $self->get_htgt_well_data_value( 'pass_level' ) || 'fail';    

    if ( defined $pass_level and exists $IS_SEQUENCING_QC_PASS{ $pass_level } ) {
        return 'pass';
    }

    return 'fail';
}

__PACKAGE__->meta->make_immutable;

1;

__END__
