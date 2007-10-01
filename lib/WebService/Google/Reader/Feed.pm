package WebService::Google::Reader::Feed;

use strict;
use base qw( XML::Atom::Feed Class::Accessor::Fast );

use constant NS_READER => 'http://www.google.com/schemas/reader/atom/';

__PACKAGE__->mk_accessors(qw( ids count request ));

sub new {
    my ($class, %params) = @_;
    return bless \%params, $class;
}

sub continuation {
    return $_[0]->get( NS_READER, 'continuation' );
}

1;

__END__

=head1 NAME

WebService::Google::Reader::Feed- subclass of C<XML::Atom::Feed>

=head1 METHODS

=over

=item $feed = WebService::Google::Reader::Feed->B<new>( %params )

=item $string = $feed->B<continuation>

Returns the continuation string, if any is present.

=back

=cut
