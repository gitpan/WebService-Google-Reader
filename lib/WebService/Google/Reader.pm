package WebService::Google::Reader;

use strict;
use base qw( Class::Accessor::Fast );

use HTTP::Request;
use HTTP::Request::Common qw( GET POST );
use LWP::UserAgent;
use JSON::Any;
use URI;
use URI::Escape;
use URI::QueryParam;

use WebService::Google::Reader::Constants;
use WebService::Google::Reader::Feed;
use WebService::Google::Reader::ListElement;

our $VERSION = '0.01_2';

__PACKAGE__->mk_accessors(qw(
    error password scheme token ua username
));

sub new {
    my ($class, %params) = @_;

    my $self = bless \%params, $class;

    my $ua = $params{ua};
    unless ( ref $ua and $ua->isa( q(LWP::UserAgent) ) ) {
        $ua = LWP::UserAgent->new(
            # Bad Google! Refuses to send compressed responses unless
            # Mozilla/ is present in the user-agent.
            agent => 'Mozilla/'.__PACKAGE__.'/'.$VERSION
        );
        $self->ua( $ua );
    }
    $ua->cookie_jar( {} ) unless $ua->cookie_jar;

    $self->scheme( $params{secure} || $params{https} ? 'https' : 'http' );

    return $self;
}

sub edit {
    my ($self, $type, $val, %params) = @_;

    $self->_login or return;
    $self->_token or return;

    my ($url, %fields);
    if ( 'feed' eq $type or 'subscription' eq $type or 'sub' eq $type ) {
        $url = EDIT_SUB_URL;

        for my $f ( ref $val eq 'ARRAY' ? @$val : ( $val ) ) {
            if ( ref $f eq __PACKAGE__.'::Feed' ) {
                my $id = $f->id or return;
                $id =~ s[^tag:google.com,2005:reader/][];
                $id =~ s[\?.*][];
                push @{ $fields{s} }, $id;
            }
            else {
                push @{ $fields{s} }, _encode_type( feed => $f );
            }
        }
        return 1 unless ref $fields{s};

        # Add a label or state.
        for my $t (qw( label tag state )) {
            next unless exists $params{ $t };
            defined( my $p = $params{ $t } ) or next;
            for my $a ( ref $p eq 'ARRAY' ? @$p : ( $p ) ) {
                push @{ $fields{a} }, _encode_type( $t => $a );
            }
        }
        # Remove a label or state.
        for my $t (qw( unlabel untag unstate )) {
            next unless exists $params{ $t };
            defined( my $p = $params{ $t } ) or next;
            substr( $t, 0, 2, '' );
            for my $d ( ref $p eq 'ARRAY' ? @$p : ( $p ) ) {
                push @{ $fields{r} }, _encode_type( $t => $d );
            }
        }

        if ( defined( my $title = $params{title} ) ) {
            $fields{t} = $title;
        }

        if ( grep { $params{ $_ } } qw( subscribe add ) ) {
            $fields{ac} = 'subscribe';
        }
        elsif ( grep { $params{ $_ } } qw( unsubscribe delete remove ) ) {
            $fields{ac} = 'unsubscribe';
        }
        else {
            $fields{ac} = 'edit';
        }
    }
    elsif ( 'label' eq $type or 'tag' eq $type ) {
        push @{ $fields{s} }, _encode_type( label => $val );
        return 1 unless @{ $fields{s} };

        if ( grep { $params{ $_ } } qw( share public ) ) {
            $url = EDIT_TAG_SHARE_URL;
            $fields{pub} = 'true';
        }
        elsif ( grep { $params{ $_ } } qw( unshare private ) ) {
            $url = EDIT_TAG_SHARE_URL;
            $fields{pub} = 'false';            
        }
        elsif ( grep { $params{ $_ } } qw( disable delete remove ) ) {
            $url = EDIT_TAG_DISABLE_URL;
            $fields{ac} = 'disable-tags';
        }
    }
    elsif ( 'entry' eq $type or 'item' eq $type ) {
        for my $e ( ref $val eq 'ARRAY' ? @$val : ( $val ) ) {
            push @{ $fields{i} }, ref $e eq 'XML::Atom::Entry' ? $e->id : $e;
        }
        return 1 unless ref $fields{i};

        # Add a label or state.
        for my $t (qw( label tag state )) {
            next unless exists $params{ $t };
            defined( my $p = $params{ $t } ) or next;
            for my $a ( ref $p eq 'ARRAY' ? @$p : ( $p ) ) {
                push @{ $fields{a} }, _encode_type( $t => $a );
            }
        }
        # Remove a label or state.
        for my $t (qw( unlabel untag unstate delabel detag destate )) {
            next unless exists $params{ $t };
            defined( my $p = $params{ $t } ) or next;
            $t =~ s/^(?:de|un)//;
            for my $d ( ref $p eq 'ARRAY' ? @$p : ( $p ) ) {
                push @{ $fields{r} }, _encode_type( $t => $d );
            }
        }
    }
    else {
        return;
    }
    
    my $uri = URI->new( $url, 'https' );
    my $req = POST( $uri, [ %fields, T => $self->token ] );
    my $res = $self->_request( $req ) or return;

    return 1 if $res->decoded_content eq 'OK';

    $self->error( 'Edit failed: '. $res->decoded_content );
    return;
}

sub unsubscribe { shift->edit( feed => [ @_ ], unsubscribe => 1 ); }
# Should this use quickadd?
sub subscribe { shift->edit( feed => [ @_ ], subscribe => 1 ); }

sub feed {
    my ($self, $type, $val, %params) = @_;

    $self->_login or return;

    my $feed;
    if ( ref $type eq __PACKAGE__.'::Feed' ) {
        $feed = $type;
        return unless defined $feed->continuation;
        $feed->request->uri->query_param( c => $feed->continuation );
    }
    else {
        my $path = $self->_public ? ATOM_PUBLIC_URL : ATOM_URL;    
        my $uri = URI->new( $path . _encode_type( $type, $val ), 1 );
    
        my %fields;
        if ( my $count = $params{count} ) {
            $fields{n} = $count;
        }
        if ( my $start_time = $params{start_time} ) {
            $fields{ot} = $start_time;
        }
        if ( my $order = $params{order} || $params{sort} ) {
             # m = magic/auto; not really sure what that is
             $fields{r} = $order eq 'desc' ? 'n' :
                          $order eq 'asc' ? 'o' : $order;
        }
        if ( defined( my $continuation = $params{continuation} ) ) {
            $fields{c} = $continuation;
        }
        if ( ref $params{exclude} eq 'HASH' ) {
            while ( my ($xtype, $exclude) = each %{ $params{exclude} } ) {
                push @{ $fields{xt} }, _encode_type( $xtype, $exclude );
            }
        }

        $uri->query_form( \%fields );

        $feed = ( __PACKAGE__.'::Feed' )->new( request => GET( $uri ) );
    }

    my $res = $self->_request( $feed->request ) or return;

    $feed->init( Stream => $res->decoded_content( ref => 1 ) );
    return $feed;
}

sub list {
    my ($self, $type) = @_;

    $self->_login or return;

    my $uri = URI->new(
        'counts' eq $type ? LIST_COUNTS_URL :
        'subs' eq $type || 'subscriptions' eq $type ? LIST_SUBS_URL :
        'tags' eq $type || 'labels' eq $type ? LIST_TAGS_URL :
        'prefs' eq $type || 'preferences' eq $type ? LIST_PREFS_URL :
        API_URL."/$type"
    );
    $uri->query_form( { $uri->query_form, output => 'json' } );

    my $res = $self->_request( GET( $uri ) ) or return;

    my $ref = eval { JSON::Any->decode( $res->decoded_content ) };
    if ( $@ ) {
       $self->error( "Failed to parse JSON response: $@" );
        return;
    }

    # Remove an unecessary level of indirection.
    my $aref = ( grep { ref eq 'ARRAY' } values %$ref )[0] || [];

    for my $ref ( @$aref ) {
        $ref = ( __PACKAGE__.'::ListElement' )->new( $ref )
    }

    return @$aref
}

*subscriptions = *subs = *feeds = sub { $_[0]->list( 'subs' ) };
*tags = *labels = sub { $_[0]->list( 'tags' ) };

sub search {
    my ($self, $query, %params) = @_;

    $self->_login or return;

    my $feed;
    if ( ref $query eq __PACKAGE__.'::Feed' ) {
        $feed = $query;
        return unless scalar @{ $feed->ids };
    }
    else {
        my $uri = URI->new( SEARCH_IDS_URL );
    
        my %fields;
        $fields{num} = $params{results} || 1000;
    
        my @types = grep { exists $params{ $_ } } qw( feed state label tag );
        for my $type (@types) {
            push @{ $fields{s} }, _encode_type( $type, $params{$type} );
        }
    
        $uri->query_form( { q => $query, %fields, output => 'json' } );
    
        my $req = HTTP::Request->new( GET => $uri );
        my $res = $self->_request( $req ) or return;
    
        my @ids = do {
            my $ref = eval { JSON::Any->decode( $res->decoded_content ) };
            if ( $@ ) {
                $self->error( "Failed to parse JSON response: $@" );
                return;
            }
            map { $_->{id} } @{ $ref->{results} };
        };
        return unless @ids;
        if ( my $order = $params{order} || $params{sort} ) {
            @ids = reverse @ids if $order eq 'asc';
        }

        $feed = ( __PACKAGE__.'::Feed' )->new(
            request => $req, ids => \@ids, count => $params{count} || 40,
        );
    }

    $self->_token or return;

    my @ids = splice @{ $feed->ids }, 0, $feed->count;
    return unless @ids;

    my $uri = URI->new( SEARCH_CONTENTS_URL, 'https' );

    my $req = POST( $uri, [ ( map { ('i', $_) } @ids ), T => $self->token ] );
    my $res = $self->_request( $req ) or return;

    $feed->init( Stream => $res->decoded_content( ref => 1 ) ) or return;
    return $feed;
}

sub opml {
    my ($self) = @_;

    $self->_login or return;

    my $req = GET( EXPORT_SUBS_URL );
    my $res = $self->_request( $req ) or return;

    return $res->decoded_content;
}

sub _login {
    my ($self, $force) = @_;

    return if $self->_public;
    return 1 if not $force and $self->_cookie;

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

    my ($sid) = $content =~ m[ ^SID=(.*)$ ]mx;
    unless ($sid) {
        $self->error( 'could not find SID value for cookie' );
        return;
    }

    $self->ua->cookie_jar->set_cookie(
        0, SID => $sid, '/', '.google.com', undef, 1, 0, 160000000000
    );

    return 1;
}

sub _request {
    my ($self, $req, $count) = @_;

    return if $count >= 3;

    # Assume all POST requests are secure.
    $req->uri->scheme( $self->scheme ) if $req->method eq 'GET';
    $req->uri->query_param( ck => time * 1000 );
    $req->uri->query_param( client => $self->ua->agent );
    $req->header( accept_encoding => HAS_ZLIB ? 'gzip,deflate' : 'identity' );

    print $req->as_string, "-"x80, "\n" if DEBUG;

    my $res = $self->ua->request( $req );
    if ( $res->is_error ) {
        # Need a fresh token.
        if ( $res->header( 'X-Reader-Google-Bad-Token' ) ) {
            $self->_token( 1 ) or return;
            return $self->_request( $req,  $count++ );
        }

        $self->error( $res->status_line . ' - ' . $res->decoded_content );
        return;
    }

    return $res;
}

# NOTE: any request that sends the token, should use https.
sub _token {
    my ($self, $force) = @_;

    return 1 if $self->token and not $force;

    $self->_login or return;

    my $uri = URI->new( TOKEN_URL, 'https' );
    my $res = $self->_request( GET( $uri ) ) or return;

    return $self->token( $res->decoded_content );
}

sub _public {
    return not $_[0]->username or not $_[0]->password;
}

sub _cookie {
    # ick, HTTP::Cookies doesn't provide an accessor.
    return $_[0]->ua->cookie_jar->{COOKIES}{'.google.com'}{'/'}{SID};
}

sub _encode_type {
    my ($type, $val, $encode_feed) = @_;
    my @paths;

    for my $v ( ref $val eq 'ARRAY' ? @$val : ( $val ) ) {
        my $path = $v;
        if ( 'feed' eq $type and 'feed/' ne substr $v, 0, 5 ) {
            $path = 'feed/' . ( $encode_feed ? uri_escape( $v ) : $v );
        }
        elsif ( $v !~ m[ ^user/(?:-|\d{20})/ ]x ) {
            my $user = '-';
            if ( $v =~ m[ ([^/]+) / (.*) ]x ) {
                ( $user, $v ) = ( $1, $2 );
            }

            if ( 'state' eq $type ) {
                $path = "user/$user/state/com.google/$v";
            }
            elsif ( 'label' eq $type or 'tag' eq $type ) {
                $path = "user/$user/label/$v"
            }
        }
        push @paths, $path;
    }

    return wantarray ? @paths : shift @paths;
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
    );

    my $feed = $reader->feed( state => 'reading-list', count => 100);
    my @entries = $feed->entries;

    # Fetch past entries.
    while ( $reader->feed( $feed ) ) {
        my @entries = $feed->entries;
    }

        
=head1 DESCRIPTION

The C<WebService::Google::Reader> module provides an interface to the
Google Reader service through the unofficial (as-yet unpublished) API.

Note, this is an alpha version.

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

Use https scheme for all requests, even when not required.

=item B<ua>

An optional useragent object.

=back

=item $retval = $reader->B<edit>

Edit subscriptions or labels. Returns true on success, false on failure.
Accepts the following named parameters:

=item $retval = $reader->B<subscribe>

=item $retval = $reader->B<unsubscribe>

=item $feed = $reader->B<feed>

Returns a subclass of XML::Atom::Feed. Accepts the following named parameters:

=over

=item B<feed> or B<state> or B<label> or B<tag>

One (and only one) of these fields must be present.

=over

=item B<feed>

The URL to a RSS / ATOM feed.

=item B<state>

One of ( read, kept-unread, fresh, starred, broadcast, reading-list, 
tracking-body-link-used, tracking-emailed, tracking-item-link-used, 
tracking-kept-unread ).

=item B<label> or B<tag>

A label / tag name.

=back

=item B<count>

The number of entries the feed will contain.

=item B<order> or B<sort>

The sort order of the entries: B<desc> (default) or B<asc>. When ordering by 
B<asc>, Google only returns items within 30 days, whereas the default order 
has no limitation.

=item B<start_time>

Request entries only newer than this time (represented as a unix timestamp).

=back

=item @list = $reader->B<list>

=item @list = $reader->B<feeds>

=item @list = $reader->B<subscriptions>

=item @list = $reader->B<subs>

=item @list = $reader->B<labels>

=item @list = $reader->B<tags>

=item $feed = $reader->B<search>

=item $opml = $reader->B<opml>

=item $error = $reader->B<error>

Returns the error, if one occurred.

=back

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
