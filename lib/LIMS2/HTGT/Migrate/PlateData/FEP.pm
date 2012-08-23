package LIMS2::HTGT::Migrate::PlateData::FEP;

use Moose;
use namespace::autoclean;

extends 'LIMS2::HTGT::Migrate::PlateData';

has '+plate_type' => (
    default => 'EP'
);

has '+lims2_plate_type' => (
    default => 'EP'
);

has '+process_type' => (
    default => 'first_electroporation'
);

override well_data => sub {
    my ( $self, $well ) = @_;
    my $data = super();
    return unless $data;

    my $cell_line = $well->well_data_value('es_cell_line')
                  || $well->plate->plate_data_value('es_cell_line');
    die "No es_cell_line set for $well" unless $cell_line;

    $data->{cell_line} = $cell_line;

    my $parent_well = $self->parent_well( $well );
    $data->{parent_plate} = $parent_well->{plate_name};
    $data->{parent_well}  = $parent_well->{well_name};
    
    return $data;
};

__PACKAGE__->meta->make_immutable;

1;

__END__
