package LIMS2::HTGT::Migrate::PlateData::VTP;

use Moose;
use LIMS2::HTGT::Migrate::Utils;
use Const::Fast;
use namespace::autoclean;

const my $DEFAULT_BACKBONE => 'R3R4_pBR_DTA+_Bsd_amp';
const my $DEFAULT_CASSETTE => 'pR6K_R1R2_ZP';

extends 'LIMS2::HTGT::Migrate::PlateData';

has '+plate_type' => (
    default => 'vtp'
);

override well_data => sub {
    my ( $self, $well ) = @_;

    my $data = super();

    $data->{cassette}   = $self->get_htgt_well_data_value( 'cassette' ) || $DEFAULT_CASSETTE;    
    $data->{backbone}   = $self->get_htgt_well_data_value( 'backbone' ) || $DEFAULT_BACKBONE;

    
    return $data;
};

__PACKAGE__->meta->make_immutable;

1;

__END__
