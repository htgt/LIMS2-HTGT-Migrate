package LIMS2::HTGT::Migrate::PlateData::Design;

use Moose;
use LIMS2::HTGT::Migrate::Utils qw( format_bac_library );
use namespace::autoclean;

extends 'LIMS2::HTGT::Migrate::PlateData';

has '+plate_type' => (
    default => 'design'
);

override well_data => sub {
    my ( $self, $well ) = @_;

    my $data = super();

    my $di = $well->design_instance;

    if ( defined $di ) {
        $data->{design_id}  = $di->design_id;
        $data->{bac_clones} = $self->bacs_for( $di );
        my ( $rec_results, $assay_pending, $assay_complete ) 
            = $self->recombineering_results_for( $well );
        $data->{assay_pending}          = $assay_pending ? $assay_pending->iso8601 : undef;
        $data->{assay_complete}         = $assay_complete ? $assay_complete->iso8601 : undef;
        $data->{assay_results}          = $rec_results;       
    }
    
    return $data;
};

sub bacs_for {
    my ( $self, $di ) = @_;

    my @bacs;

    for my $di_bac ( $di->design_instance_bacs ) {
        next unless defined $di_bac->bac_plate;        
        my $bac = $di_bac->bac;
        push @bacs, {
            bac_plate   => substr( $di_bac->bac_plate, -1 ),
            bac_name    => $self->trim( $bac->remote_clone_id ),
            bac_library => format_bac_library( $bac->clone_lib->library )
        }
    }

    return \@bacs;
}

sub recombineering_results_for {
    my ( $self, $well ) = @_;

    my ( @rec_results, $assay_pending, $assay_complete );

    for my $assay ( qw( rec_g rec_d rec_u rec_ns pcr_u pcr_d pcr_g postcre rec-result ) ) {
        my $r = $self->get_htgt_well_data( $assay )
            or next;
        ( my $assay_name = $assay ) =~ s/-/_/g;
        my $created_at = $self->parse_oracle_date( $r->edit_date ) || $self->created_date;
        if ( not defined $assay_pending or $assay_pending > $created_at ) {
            $assay_pending = $created_at;            
        }
        if ( not defined $assay_complete or $assay_complete < $created_at ) {
            $assay_complete = $created_at;
        }        
        push @rec_results, {
            assay      => $assay_name,
            result     => $self->trim( $r->data_value ),
            created_by => $r->edit_user || $self->migrate_script,
            created_at => $created_at->iso8601
        };
    }

    return ( \@rec_results, $assay_pending, $assay_complete );
}

__PACKAGE__->meta->make_immutable;

1;

__END__


