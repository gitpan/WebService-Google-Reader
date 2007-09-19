package WebService::Google::Reader::Feed;

use strict;
use base qw( XML::Atom::Feed Class::Accessor::Fast );

use constant NS_READER => 'http://www.google.com/schemas/reader/atom/';

__PACKAGE__->mk_accessors(qw( continue public reader request ));

sub new {
    my ($class, %params) = @_;
    my $self = bless {}, $class;

    $self->{ $_ } = delete $params{ $_ } or return for qw( reader request );
    if ( exists $params{continue} ) {
        $self->continue( delete $params{continue} );
    }
    else {
        $self->continue( $self->reader->continue );
    }

    $self->public( delete $params{public} || $self->reader->public );


    $self->init( %params );
use Data::Dump qw(dump);
print dump($self), "\n";
#exit;
    return $self;
}

sub init {
    my ($self, %params) = @_;
    $self->SUPER::init( %params );
    $self->{entries} = [ $self->entries ],
}

sub continuation {
    return $_[0]->get( NS_READER, 'continuation' );
}

sub entry {
    my ($self) = @_;

    if ( my $entry = shift @{ $self->{entries} } ) {
        return $entry;
    }

    return unless $self->continue and defined $self->continuation;
    return unless $self->previous;

    # Sleep between requests. Negative value will result in no sleep.
    select undef, undef, undef, $self->continue;

    return $self->entry;
}

sub previous {
    my ($self) = @_;

    my $req = $self->request;
    $req->uri->query_form( $req->uri->query_form, c => $self->continuation );
    my $res = $self->reader->_request( $req ) or return;

    $self->init( Stream => $res->decoded_content( ref => 1 ) );
    return 1;
}

1;

__END__

=head1 NAME

WebService::Google::Reader::Feed - Subclass of XML::Atom::Feed

=head1 SYNOPSIS

    $feed = $reader->feed(
        feed => 'http://example.com/atom.xml', continue => 1
    );

Iterator:

    while ( my $entry = $feed->entry ) {
       ...
    }

Batch:

    do {
        my @entries = $feed->entries;
        ...
    } while ( $feed->previous );

=head1 DESCRIPTION

This is a subclass of C<XML::Atom::Feed>, which "continues" a feed if
requested. Google Reader includes a continuation token indicating more entries
are available.

=head1 METHODS

=over

=item B<entry>

Iterates through the feed entries, one at a time. Automatically requests
previous entries if the C<continue> option is specified.

=item B<previous>

This is used internally by the C<entry> iterator, but can used explicitly if
using the C<entries> method.

=item B<continuation>

Accessor to the C<continuation> token.

=item new and init

Only mentioned to shut up Pod::Coverage

=back

=head1 SEE ALSO

L<XML::Atom::Feed>

L<WebService::Google::Reader>

=cut
