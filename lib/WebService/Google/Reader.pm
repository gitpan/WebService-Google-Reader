package WebService::Google::Reader;

use strict;
use base qw( Class::Accessor::Fast );

use LWP::UserAgent;
use HTTP::Request;
use URI;
use URI::Escape qw( uri_escape );

use WebService::Google::Reader::Feed;

our $VERSION = '0.01_1';

use constant DEBUG => $ENV{ WEBSERVICE_GOOGLE_READER_DEBUG } || 0;
use constant LOGIN_URL => 'https://www.google.com/accounts/ClientLogin';
use constant READER_URL => 'http://www.google.com/reader';

__PACKAGE__->mk_accessors(qw(
    continue cookie error password scheme response ua username
));

sub new {
    my ($class, %params) = @_;

    unless ( ref $params{ua} and $params{ua}->isa( q(LWP::UserAgent) ) ) {
        $params{ua} = LWP::UserAgent->new( agent => __PACKAGE__.'/'.$VERSION );
    }
    $params{scheme} = $params{secure} || $params{https} ? 'https' : 'http';

    return bless \%params, $class;
}

sub public {
    my ($self, $set) = @_;
    if ( $set ) {
        $self->username( undef );
        $self->password( undef );
        return;
    }
    return not $self->username and not $self->password;
}

# POST request
sub login {
    my ($self, $force) = @_;

    return if $self->public;
    return 1 if not $force and $self->cookie;

    my $uri = URI->new( LOGIN_URL );
    $uri->query_form(
        service  => 'reader',
        Email    => $self->username,
        Passwd   => $self->password,
        source   => $self->ua->agent,
        continue => READER_URL,
    );
    my $res = $self->ua->post( $uri );
    my $content = $res->decoded_content;
    if ( $res->is_error ) {
        my ($err) = $content =~ m[ ^Error=(.*)$ ]mx;
        $self->error( $res->status_line . $err ? (': '. $err) : '' );
        return;
    }

    my ($sid) = $content =~ m[ ^(SID=.*)$ ]mx;
    unless ($sid) {
        $self->error( 'could not find SID value for cookie' );
        return;
    }
    $self->cookie( $sid );

    return 1;
}

sub _type_path {
    my ($type, $val, $user) = @_;
    $user ||= '-';
    return 'feed'  eq $type ? 'feed/' . uri_escape( $val ) :
           'state' eq $type ? "user/$user/state/com.google/$val" :    
           'label' eq $type or 'tag' eq $type ? "user/$user/label/$val" : $val;
}

# GET request.
sub feed {
    my ($self, %params) = @_;

    my $public = $params{public} || $self->public;
    $self->login or return unless $public;

    my $type = do {
        my @type = grep { exists $params{ $_ } } qw( feed state label tag );
        if ( 1 != @type ) {
            $self->error( 'one of "feed", "state" or "label" must be specified' );
            return;
        }
        shift @type;
    };

    my $user = '-';
    if ( $public ) {
        $user = $params{user};
        if ( not $user and grep { $type eq $_ } qw( state label ) ) {
            $self->error( q(missing "user" field) );
            return;
        }
    }    

    my $path = $public ? '/public/atom/' : '/atom/'; 
    my $uri = URI->new(
        READER_URL . $path . _type_path( $type, $params{ $type }, $user )
    );

    my %fields;
    if ( my $count = $params{count} ) {
        $fields{n} = $count;
    }
    # TODO: Is this unix time or millitime?
    if ( my $start_time = $params{start_time} ) {
        $fields{ot} = $start_time;
    }
    if ( my $order = $params{order} ) {
         # m = magic/auto; not really sure what that is
         $fields{r} = $order eq 'desc' ? 'd' : $order eq 'asc' ? 'o' : $order;
    }

# Probably need to check for scalar, aref, and href of scalars/arefs
#    if ( my $exclude = $params{exclude} ) {
#        if ( ref $exclude eq 'ARRAY' ) {
#            while ( my ( $type, $val ) = splice @$exclude, 0, 2 ) {
#                push @{ $fields{xt} }, _type_path( $type, $val );
#            }
#        }
#        elsif ( ref $exclude eq 'HASH' ) {
#            while 
#            $fields{xt} = _type_path( $exclude );
#        }
#    }

    $uri->query_form( \%fields );

    my $req = HTTP::Request->new( GET => $uri );
    my $res = $self->_request( $req, $public ) or return;

    my %args;
    if ( exists $params{continue} ) {
        $args{continue} = $params{continue};
    }

    my $feed = WebService::Google::Reader::Feed->new(
        Stream => $res->decoded_content(ref => 1),
        reader => $self, request => $req,
        public => $public,
        %args,
    );

    return $feed;
}

my $ENCODINGS = eval { require Compress::Zlib; 1 } ? 'gzip,deflate' : '';

sub _request {
    my ($self, $req, $public) = @_;

    # All POST requests are secure.
    $req->uri->scheme( $self->scheme ) if $req->method eq 'GET';

    $req->uri->query_form(
        $req->uri->query_form, ck => time * 1000, client => $self->ua->agent
    );
    $req->header( cookie => $self->cookie ) unless $public;
    $req->header( accept_encoding => $ENCODINGS );

    my $res = $self->ua->request( $req );
    if ( $res->is_error ) {
        $self->error( $res->status_line );
        return;
    }

    return $res;
}

1;

__END__

=head1 NAME

WebService::Google::Reader - Perl interface for Google Reader

=head1 SYNOPSIS

    use WebService::Google::Reader;

    my $reader = WebService::Google::Reader->new(
        username => $user,
        password => $pass,
        continue => 1,
    );

    my $feed = $reader->feed( state => 'reading-list', count => 100);
    while ( my $entry = $feed->entry ) {
        print $entry->title, "\n";
    }

=head1 DESCRIPTION

The C<WebService::Google::Reader> module provides an interface to the
Google Reader service through the unofficial (as-yet unpublished) API.

Note, this is an alpha version and is missing many features. The API of this
module is also subject to change.

=head1 METHODS

=over

=item $reader = WebService::Google::Reader->B<new>

Creates a new WebService::Google::Reader object. The constructor accepts the
following named parameters:

=over

=item B<username> and B<password>

Required for accessing any personalized or account-related functionality
(reading-list, editing, etc.).

=item B<secure> or B<https>

Use https scheme for all requests.

=item B<continue>

When iterating over a feed using the B<entry> iterator, this indicates previous
entries should be automatically fetched when the iterator is exhausted and if
the feed indicates it has more entries available.

The value of this field indicates the number of seconds to delay (can be
fractional) between continued requests. Use a negative number to avoid any
delay.

=item B<ua>

An optional useragent object.

=back

=item $status = $reader->B<login>

Sends a request to get the SID value for the cookie header. It is not required
to explicitly call this method, as the other methods will do so when required.

=item $feed = $reader->B<feed>

Returns a subclass of XML::Atom::Feed. Accepts the following named parameters:

=over

=item B<feed> or B<state> or B<label> or B<tag>

One (and only one) of these fields must be present.

=over

=item B<feed>

The URL to a RSS / ATOM feed.

=item <state>

One of ( read, kept-unread, fresh, starred, broadcast, reading-list, 
tracking-body-link-used, tracking-emailed, tracking-item-link-used, 
tracking-kept-unread ).

=item B<label> or B<tag>

A label / tag name.

=back

=item B<continue>

A feed-specific setting. See C<new> for a full description of this field.

=item B<count>

The number of entries the feed will contain.

=item B<order>

The sort order of the entries: B<desc> (default) or B<asc>.

=item B<start_time>

Request entries only newer than this time (represented as a unix timestamp).

=back

=item $error = $reader->B<error>

Returns the error, if one occurred.

=back

=head1 ACCESSORS

=over

=item public

=back

=head1 TODO

Lots!

=head1 SEE ALSO

L<http://code.google.com/p/pyrfeed/wiki/GoogleReaderAPI>

=head1 REQUESTS AND BUGS

Please report any bugs or feature requests to 
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=WebService-Google-Reader>. I will be 
notified, and then you'll automatically be notified of progress on your bug as 
I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc WebService::Google::Reader

You can also look for information at:

=over

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/WebService-Google-Reader>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/WebService-Google-Reader>

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=WebService-Google-Reader>

=item * Search CPAN

L<http://search.cpan.org/dist/WebService-Google-Reader>

=back

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2007 gray <gray at cpan.org>, all rights reserved.

This library is free software; you can redistribute it and/or modify it under 
the same terms as Perl itself.

=head1 AUTHOR

gray, <gray at cpan.org>

=cut
