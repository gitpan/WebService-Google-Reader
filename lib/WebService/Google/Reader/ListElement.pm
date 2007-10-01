package WebService::Google::Reader::ListElement;

use strict;
use base qw( Class::Accessor::Fast );

__PACKAGE__->mk_ro_accessors(qw(
    id categories count firstitemmsec label shared title value
));

sub new {
    my ($class, $ref) = @_;
    my $self = bless $ref, $class;
    if ( exists $self->{categories} ) {
        for my $cat ( @{ $self->{categories} } ) {
            $cat = __PACKAGE__->new( $cat );
        }
    }
    return $self;
}

use overload q("") => sub { $_[0]->id };

1;

__END__

=head1 NAME

WebService::Google::Reader::ListItem

=head1 SYNOPSIS

    my @list = $reader->list( 'subscriptions' );
    for my $elm (@list) {
        print $list, "\n";
    }

=head1 DESCRIPTION

This module provides the following accessors. Each list type populates a 
different subset of the fields. Stringifying a ListElement will return the 
contents the B<id> field.

=over

=item id

=item categories

This is a list of ListElements.

=item count

=item firstitemmsec

=item label

=item shared

=item title

=item value

=back

=head1 METHODS

=over

=item $elm = WebService::Google::Reader::ListElement->B<new>( $ref )

=back

=head1 SEE ALSO

L<WebService::Google::Reader>

=cut
