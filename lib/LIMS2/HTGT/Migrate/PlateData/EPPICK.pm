package LIMS2::HTGT::Migrate::PlateData::EPPICK;

use Moose;
use namespace::autoclean;

extends 'LIMS2::HTGT::Migrate::PlateData';

has '+plate_type' => (
    default => 'EPD'
);

has '+lims2_plate_type' => (
    default => 'EP_PICK'
);

has '+process_type' => (
    default => 'clone_pick'
);

override well_data => sub {
    my ( $self, $well ) = @_;
    my $data = super();
    return unless $data;

    my $parent_well = $self->parent_well( $well );
    $data->{parent_plate} = $parent_well->{plate_name};
    $data->{parent_well}  = $parent_well->{well_name};
    
    return $data;
};

__PACKAGE__->meta->make_immutable;

1;

__END__
