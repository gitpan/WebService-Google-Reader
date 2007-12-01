package WebService::Google::Reader;

use strict;
use warnings;
use base qw( Class::Accessor::Fast );

use HTTP::Cookies;
use HTTP::Request::Common qw( GET POST );
use LWP::UserAgent;
use JSON::Any;
use URI::Escape;
use URI::QueryParam;

use WebService::Google::Reader::Constants;
use WebService::Google::Reader::Feed;
use WebService::Google::Reader::ListElement;

our $VERSION = '0.07';

if ( DEBUG ) {
    require Carp;
    @SIG{qw( __DIE__ __WARN__ )} = \( &Carp::confess, &Carp::cluck );
}

__PACKAGE__->mk_accessors(qw(
    error password scheme token ua username
));

sub new {
    my ($class, %params) = @_;

    my $self = bless \%params, $class;

    my $ua = $params{ua};
    unless ( ref $ua and $ua->isa( q(LWP::UserAgent) ) ) {
        $ua = LWP::UserAgent->new(
            # Google only compresses content for certain agents or if gzip
            # is part of the agent name.
            agent => __PACKAGE__.'/'.$VERSION . ( HAS_ZLIB ? ' (gzip)' :'' )
        );
        $self->ua( $ua );
    }
    unless ( $ua->cookie_jar ) {
        $ua->cookie_jar( HTTP::Cookies->new( hide_cookie2 => 1 ) );
    }

    $self->scheme( $params{secure} || $params{https} ? 'https' : 'http' );

    return $self;
}

## Feeds

sub feed {
    return shift->_feed( feed => shift, @_ );
}

sub tag {
    return shift->_feed( tag => shift, @_ );
}

sub state {
    return shift->_feed( state => shift, @_ );
}

sub shared {
    return shift->state( 'broadcast', @_ );
}

sub starred {
    return shift->state( 'starred', @_ );
}

sub unread {
    return shift->state( 'reading-list', exclude => { state => 'read' }, @_ );
}

sub search {
    my ($self, $query, %params) = @_;

    $self->_login or return;
    $self->_token or return;

    my $uri = URI->new( SEARCH_IDS_URL );

    my %fields;
    $fields{num} = $params{results} || 1000;

    my @types = grep { exists $params{ $_ } } qw( feed state tag );
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
        @ids = reverse @ids if 'asc' eq $order;
    }

    my $feed = ( __PACKAGE__.'::Feed' )->new(
        request => $req, ids => \@ids, count => $params{count} || 40,
    );
    return $self->more( $feed );
}

sub more {
    my ($self, $feed) = @_;

    my $req;
    if ( defined $feed->ids ) {
        my @ids = splice @{ $feed->ids }, 0, $feed->count;
        return unless @ids;

        my $uri = URI->new( STREAM_IDS_CONTENT_URL, 'https' );
        $req = POST( $uri, [ ( map { ('i', $_) } @ids ), T => $self->token ] );
    }
    elsif ( $feed->elem ) {
        return unless defined $feed->continuation and $feed->entries;
        $req = $feed->request;
        $req->uri->query_param( c => $feed->continuation );
    }
    elsif ( $req = $feed->request ) {
        # Initial request.
    }
    else { return }

    my $res = $self->_request( $req ) or return;

    $feed->init( Stream => $res->decoded_content( ref => 1 ) ) or return;
    return $feed;
}

*previous = *next = \&more;

## Lists

sub tags {
    return $_[0]->_list( LIST_TAGS_URL );
}

sub feeds {
    return $_[0]->_list( LIST_SUBS_URL );
}

sub preferences {
    return $_[0]->_list( LIST_PREFS_URL );
}

sub counts {
    return $_[0]->_list( LIST_COUNTS_URL );
}

sub userinfo {
    my ($self) = @_;
    return $_[0]->_list( LIST_USER_INFO_URL );
}

## Edit tags

sub edit_tag  {
    return shift->_edit_tag( tag => @_ );
}

sub edit_state {
    return shift->_edit_tag( state => @_ );
}

sub share_tag {
    return shift->edit_tag( \@_, share => 1 );
}

sub unshare_tag {
    return shift->edit_tag( \@_, unshare => 1 );
}

sub share_state {
    return shift->edit_state( \@_, share => 1 );
}

sub unshare_state {
    return shift->edit_state( \@_, unshare => 1 );
}

sub delete_tag {
    return shift->edit_tag( \@_, delete => 1 );
}

sub mark_read_tag {
    return shift->mark_read( tag => \@_ );
}

sub mark_read_state {
    return shift->mark_read( state => \@_ );
}

sub rename_feed_tag {
    my ($self, $old, $new) = @_;

    my @tagged;
    my @feeds = $self->feeds or return;

    # Get the list of subs which are associated with the tag to be renamed.
    FEED:
    for my $feed ( @feeds ) {
        for my $cat ( $self->categories ) {
            for my $o ( 'ARRAY' eq ref $old ? @$old : ( $old ) ) {
                if ( $old eq $cat->label or $old eq $cat->id ) {
                    push @tagged, $feed->id;
                    next FEED;
                }
            }
        }
    }

    $_ = [ _encode_type( tag => $_) ] for ( $old, $new );

    return $self->edit_feed( \@tagged, tag => $new, untag => $old );
}

sub rename_entry_tag {
    my ($self, $old, $new) = @_;

    for my $o ( 'ARRAY' eq ref $old ? @$old : ( $old ) ) {
        my $feed = $self->tag( $o ) or return;
        do {
            $self->edit_entry( [ $feed->entries ], tag => $new, untag => $old )
                or return;
        } while ( $self->feed( $feed ) );
    }

    return 1;
}

sub rename_tag {
    my $self = shift;
    return unless $self->rename_tag_feed( @_ );
    return unless $self->rename_tag_entry( @_ );
    return $self->delete_tags( shift );
}

## Edit feeds

sub edit_feed {
    my ($self, $sub, %params) = @_;

    $self->_login or return;
    $self->_token or return;

    my $url = EDIT_SUB_URL;

    my %fields;
    for my $s ( 'ARRAY' eq ref $sub ? @$sub : ( $sub ) ) {
        if ( __PACKAGE__.'::Feed' eq ref $s ) {
            my $id = $s->id or next;
            $id =~ s[^tag:google.com,2005:reader/][];
            $id =~ s[\?.*][];
            push @{ $fields{s} }, $id;
        }
        else {
            push @{ $fields{s} }, _encode_type( feed => $s );
        }
    }
    return 1 unless @{ $fields{s} || [] };

    if ( defined( my $title = $params{title} ) ) {
        $fields{t} = $title;
    }

    if ( grep { exists $params{ $_ } } qw( subscribe add ) ) {
        $fields{ac} = 'subscribe';
    }
    elsif ( grep { exists $params{ $_ } } qw( unsubscribe remove ) ) {
        $fields{ac} = 'unsubscribe';
    }
    else {
        $fields{ac} = 'edit';
    }

    # Add a tag or state.
    for my $t (qw( tag state )) {
        next unless exists $params{ $t };
        defined( my $p = $params{ $t } ) or next;
        for my $a ( 'ARRAY' eq ref $p ? @$p : ( $p ) ) {
            push @{ $fields{a} }, _encode_type( $t => $a );
        }
    }
    # Remove a tag or state.
    for my $t (qw( untag unstate )) {
        next unless exists $params{ $t };
        defined( my $p = $params{ $t } ) or next;
        for my $d ( 'ARRAY' eq ref $p ? @$p : ( $p ) ) {
            push @{ $fields{r} }, _encode_type( substr( $t, 2 ) => $d );
        }
    }

    return $self->_edit( $url, %fields );
}

sub tag_feed {
    return shift->edit_feed( shift, tag => \@_ );
}

sub untag_feed {
    return shift->edit_feed( shift, untag => \@_ );
}

sub state_feed {
    return shift->edit_feed( shift, state => \@_ );
}

sub unstate_feed {
    return shift->edit_feed( shift, unstate => \@_ );
}

sub subscribe {
    return shift->edit_feed( \@_, subscribe => 1 );
}

sub unsubscribe {
    return shift->edit_feed( \@_, unsubscribe => 1 );
}

sub rename_feed {
    return $_[0]->edit_feed( $_[1], title => $_[2] );
}

sub mark_read_feed {
    return shift->mark_read( feed => \@_ );
}

## Edit entries

sub edit_entry {
    my ($self, $entry, %params) = @_;

    $self->_login or return;
    $self->_token or return;

    my %fields = ( ac => 'edit' );
    for my $e ( 'ARRAY' eq ref $entry ? @$entry : ( $entry ) ) {
        push @{ $fields{i} }, $e->id;
        push @{ $fields{s} }, $e->stream_id;
    }
    return 1 unless @{ $fields{i} || [] };

    my $url = EDIT_ENTRY_TAG_URL;

    # Add a tag or state.
    for my $t (qw( tag state )) {
        next unless exists $params{ $t };
        defined( my $p = $params{ $t } ) or next;
        for my $a ( 'ARRAY' eq ref $p ? @$p : ( $p ) ) {
            push @{ $fields{a} }, _encode_type( $t => $a );
        }
    }
    # Remove a tag or state.
    for my $t (qw( untag unstate )) {
        next unless exists $params{ $t };
        defined( my $p = $params{ $t } ) or next;
        for my $d ( 'ARRAY' eq ref $p ? @$p : ( $p ) ) {
            push @{ $fields{r} }, _encode_type( substr( $t, 2 ) => $d );
        }
    }

    return $self->_edit( $url, %fields );
}

sub tag_entry {
    return shift->edit_entry( shift, tag => \@_ );
}

sub untag_entry {
    return shift->edit_entry( shift, untag => \@_ );
}

sub state_entry {
    return shift->edit_entry( shift, state => \@_ );
}

sub unstate_entry {
    return shift->edit_entry( shift, unstate => \@_ );
}

sub share_entry {
    return shift->edit_entry( shift, state => 'broadcast' );
}

sub unshare_entry {
    return shift->edit_entry( shift, unstate => 'broadcast' );
}

sub star_entry {
    return shift->edit_entry( shift, state => 'starred' );
}

*star = \&star_entry;

sub unstar_entry {
    return shift->edit_entry( shift, unstate => 'starred' );
}

*unstar = \&unstar_entry;

sub mark_read_entry {
    return shift->edit_entry( \@_, state => 'read' );
}

## Miscellaneous

sub mark_read {
    my ($self, %params) = @_;

    $self->_login or return;
    $self->_token or return;

    my %fields;
    my @types = grep { exists $params{ $_ } } qw( feed state tag );
    for my $type (@types) {
        push @{ $fields{s} }, _encode_type( $type, $params{$type} );
    }

    return $self->_edit( EDIT_MARK_READ_URL, %fields );
}

sub edit_preference {
    my ($self, $key, $val) = @_;

    $self->_login or return;
    $self->_token or return;

    return $self->_edit( EDIT_PREF_URL, k => $key, v => $val );
}

sub opml {
    my ($self) = @_;

    $self->_login or return;

    my $req = GET( EXPORT_SUBS_URL );
    my $res = $self->_request( $req ) or return;

    return $res->decoded_content;
}

sub ping {
    my ($self, %fields) = @_;
    my $res = $self->_request( GET( PING_URL ) ) or return;

    return 1 if 'OK' eq $res->decoded_content;

    $self->error( 'Ping failed: '. $res->decoded_content );
    return;
}


## Private interface

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
        $self->error( $res->status_line . ( $err ? (': '. $err) : '' ) );

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

    return if $count and 2 <= $count;

    # Assume all POST requests are secure.
    $req->uri->scheme( $self->scheme ) if 'GET' eq $req->method;
    $req->uri->query_param( ck => time * 1000 );
    $req->uri->query_param( client => $self->ua->agent );

    print $req->as_string, "-"x80, "\n" if DEBUG;

    if ( HAS_ZLIB ) {
        $req->header( accept_encoding => 'gzip,deflate' );
        # Doesn't always work; gets 415- unsupported media type for some urls.
        #if ( my $content = $req->content ) {
        #    if ( $content = Compress::Zlib::memGzip( $content ) ) {
        #        $req->content( $content );
        #        $req->content_length( length $content );
        #        $req->content_encoding( 'gzip' );
        #    }
        #}
    }

    my $res = $self->ua->request( $req );
    if ( $res->is_error ) {
        # Need a fresh token.
        if ( $res->header( 'X-Reader-Google-Bad-Token' ) ) {
            print "Stale token- retrying\n" if DEBUG;
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
    my ($type, $val, $escape) = @_;
    my @paths;

    if ( 'feed' eq $type ) {
        @paths = _encode_feed( $val, $escape);
    }
    elsif ( 'tag' eq $type ) {
        @paths = _encode_tag( $val );
    }
    elsif ( 'state' eq $type ) {
        @paths = _encode_state( $val );
    }
    elsif ( 'entry' eq $type ) {
        @paths = _encode_entry( $val );
    }
    else {
        return;
    }

    return wantarray ? @paths : shift @paths;
}

sub _encode_feed {
    my ($feed, $escape) = @_;

    my @paths;
    for my $f ( 'ARRAY' eq ref $feed ? @$feed : ( $feed ) ) {
        my $path = $f;
        if ( 'feed/' ne substr $f, 0, 5 ) {
            $path = 'feed/' . $escape ? uri_escape( $f ) : $f;
        }
        push @paths, $path;
    }

    return @paths;
}

sub _encode_tag {
    my ($tag) = @_;

    my @paths;
    for my $t ( 'ARRAY' eq ref $tag ? @$tag : ( $tag ) ) {
        my $path = $t;
        if ( $t !~ m[ ^user/(?:-|\d{20})/ ]x ) {
            $path = "user/-/label/$t"
        }
        push @paths, $path;
    }

    return @paths;
}

sub _encode_state {
    my ($state) = @_;

    my @paths;
    for my $s ( 'ARRAY' eq ref $state ? @$state : ( $state ) ) {
        my $path = $s;
        if ( $s !~ m[ ^user/(?:-|\d{20})/ ]x ) {
            $path = "user/-/state/com.google/$s";
        }
        push @paths, $path;
    }

    return @paths;
}

sub _encode_entry {
    my ($entry) = @_;

    my @paths;
    for my $e ( 'ARRAY' eq ref $entry ? @$entry : ( $entry ) ) {
        my $path = $e;
        if ( 'tag:google.com,2005:reader/item/' ne substr $e, 0, 32 ) {
            $path = "tag:google.com,2005:reader/item/$e";
        }
        push @paths, $path;
    }

    return @paths;
}

sub _feed {
    my ($self, $type, $val, %params) = @_;

    $self->_login or return;

    my $path = $self->_public ? ATOM_PUBLIC_URL : ATOM_URL;
    my $uri = URI->new( $path . _encode_type( $type, $val, 1 ) );

    my %fields;
    if ( my $count = $params{count} ) {
        $fields{n} = $count;
    }
    if ( my $start_time = $params{start_time} ) {
        $fields{ot} = $start_time;
    }
    if ( my $order = $params{order} || $params{sort} ) {
            # m = magic/auto; not really sure what that is
            $fields{r} = 'desc' eq $order ? 'n' :
                         'asc' eq $order ? 'o' : $order;
    }
    if ( defined( my $continuation = $params{continuation} ) ) {
        $fields{c} = $continuation;
    }
    if ( my $ex = $params{exclude} ) {
        for my $x ( 'ARRAY' eq ref $ex ? @$ex : ( $ex ) ) {
            while ( my ($xtype, $exclude) = each %$x ) {
                push @{ $fields{xt} }, _encode_type( $xtype, $exclude );
            }
        }
    }

    $uri->query_form( \%fields );

    my $feed = ( __PACKAGE__.'::Feed' )->new( request => GET( $uri ) );
    return $self->more( $feed );
}

sub _list {
    my ($self, $url) = @_;

    $self->_login or return;

    my $uri = URI->new( $url );
    $uri->query_form( { $uri->query_form, output => 'json' } );

    my $res = $self->_request( GET( $uri ) ) or return;

    my $ref = eval { JSON::Any->decode( $res->decoded_content ) };
    if ( $@ ) {
       $self->error( "Failed to parse JSON response: $@" );
        return;
    }

    # Remove an unecessary level of indirection.
    my $aref = ( grep { 'ARRAY' eq ref } values %$ref )[0] || [];

    for my $ref ( @$aref ) {
        $ref = ( __PACKAGE__.'::ListElement' )->new( $ref )
    }

    return @$aref
}

sub _edit {
    my ($self, $url, %fields) = @_;
    my $uri = URI->new( $url, 'https' );
    my $req = POST( $uri, [ %fields, T => $self->token ] );
    my $res = $self->_request( $req ) or return;

    return 1 if 'OK' eq $res->decoded_content;

    # TODO: is there a standard error format which can be reliably parsed?
    $self->error( 'Edit failed: '. $res->decoded_content );
    return;
}

sub _edit_tag {
    my ($self, $type, $tag, %params) = @_;

    $self->_login or return;
    $self->_token or return;

    my %fields;
    push @{ $fields{s} }, _encode_type( $type => $tag );
    return 1 unless @{ $fields{s} || [] };

    my $url;
    if ( grep { exists $params{ $_ } } qw( share public ) ) {
        $url = EDIT_TAG_SHARE_URL;
        $fields{pub} = 'true';
    }
    elsif ( grep { exists $params{ $_ } } qw( unshare private ) ) {
        $url = EDIT_TAG_SHARE_URL;
        $fields{pub} = 'false';
    }
    elsif ( grep { exists $params{ $_ } } qw( disable delete ) ) {
        $url = EDIT_TAG_DISABLE_URL;
        $fields{ac} = 'disable-tags';
    }
    else {
        $self->error( 'Unknown action' );
        return;
    }

    return $self->_edit( $url, %fields );
}

sub _states {
    return qw(
        read kept-unread fresh starred broadcast reading-list
        tracking-body-link-used tracking-emailed tracking-item-link-used
        tracking-kept-unread
    );
}

1;

__END__

=head1 NAME

WebService::Google::Reader - Perl interface to Google Reader

=head1 SYNOPSIS

    use WebService::Google::Reader;

    my $reader = WebService::Google::Reader->new(
        username => $user,
        password => $pass,
    );

    my $feed = $reader->unread( count => 100 );
    my @entries = $feed->entries;

    # Fetch past entries.
    while ( $reader->more( $feed ) ) {
        my @entries = $feed->entries;
    }


=head1 DESCRIPTION

The C<WebService::Google::Reader> module provides an interface to the
Google Reader service through the unofficial (as-yet unpublished) API.

=head1 METHODS

=over

=item $reader = WebService::Google::Reader->B<new>

Creates a new WebService::Google::Reader object. The following named parameters
are accepted:

=over

=item B<username> and B<password>

Required for accessing any personalized or account-related functionality
(reading-list, editing, etc.).

=item B<https> / B<secure>

Use https scheme for all requests, even when not required.

=item B<ua>

An optional useragent object.

=back

=item $error = $reader->B<error>

Returns the error, if one occurred.

=back

=head2 Feed generators

The following methods request an ATOM feed and return a subclass of
C<XML::Atom::Feed>. These methods accept the following optional named
parameters:

=over

=over

=item B<order> / B<sort>

The sort order of the entries: B<desc> (default) or B<asc> in time. When
ordering by B<asc>, Google only returns entries within 30 days, whereas the
default order has no limitation.

=item B<start_time>

Request entries only newer than this time (represented as a unix timestamp).

=item B<exclude>( feed => $feed|[@feeds], tag => $tag|[@tags] )

Accepts a hash reference to one or more of feed / tag / state. Each of which
is a scalar or array reference.

=back

=back

=over

=item B<feed>( $feed )

Accepts a single feed url.

=item B<tag>( $tag )

Accepts a single tag name. See L</TAGS>

=item B<state>( $state )

Accepts a single state name. See L</STATES>.

=item B<shared>

Shortcut for B<state>( 'broadcast' ).

=item B<starred>

Shortcut for B<state>( 'starred' ).

=item B<unread>

Shortcut for B<state>( 'reading-list', exclude => { state => 'read' } )

=back

=over

=item B<search>( $query, %params )

Accepts a query string and the following named parameters:

=over

=item B<feed> / B<state> / B<tag>

One or more (as a array reference) feed / state / tag to search. The default
is to search all feed subscriptions.

=item B<results>

The total number of search results: defaults to 1000.

=item B<count>

The number of entries per fetch: defaults to 40.

=item B<order> / B<sort>

The sort order of the entries: B<desc> (default) or B<asc> in time.

=back

=item B<more> / B<previous> / B<next>

A feed generator only returns B<$count> entries. If more are available, calling
this method will return a feed with the next B<$count> entries.

=back

=head2 List generators

The following methods return an object of type
C<WebService::Google::Reader::ListElement>.

=over

=item B<counts>

Returns a list of subscriptions and a count of unread entries. Also listed are
any tags or states which have positive unread counts. The following accessors
are provided: id, count. The maximum count reported is 1000.

=item B<feeds>

Returns the list of user subscriptions. The following accessors are provided:
id, title, categories, firstitemmsec. categories is a reference to a list of
C<ListElement>s providing accessors: id, label.

=item B<preferences>

Returns the list of preference settings. The following accessors are
provided: id, value.

=item B<tags>

Returns the list of user-created tags. The following accessors are provided:
id, shared.

=item B<userinfo>

Returns the list of user information. The following accessors are provided:
isBloggerUser, userId, userEmail.

=back

=head2 Edit feeds

The following methods are used to edit feed subscriptions.

=over

=item B<edit_feed>( $feed|[@feeds], %params )

Requires a feed url or Feed object, or a reference to a list of them.
The following named parameters are accepted:

=over

=item B<subscribe> / B<unsubscribe>

Flag indicating whether the target feeds should be added or removed from the
user's subscriptions.

=item B<title>

Accepts a title to associate with the feed. This probaby wouldn't make sense
to use when there are multiple feeds. (Maybe later will consider allowing a
list here and zipping the feed and title lists).

=item B<tag> / B<state> / B<untag> / B<unstate>

Accepts a tag / state or a reference to a list of tags / states for which to
associate / unassociate the target feeds.

=back

=item B<tag_feed>( $feed|[@feeds], @tags )

=item B<untag_feed>( $feed|[@feeds], @tags )

=item B<state_feed>( $feed|[@feeds], @states )

=item B<unstate_feed>( $feed|[@feeds], @states )

Associate / unassociate a list of tags / states from a feed / feeds.

=item B<subscribe>( @feeds )

=item B<unsubscribe>( @feeds )

Subscribe or unsubscribe from a list of feeds.

=item B<rename_feed>( $feed|[@feeds], $title )

Renames a feed to the given title.

=item B<mark_read_feed>( @feeds )

Marks the feeds as read.

=back

=head2 Edit tags / states

The following methods are used to edit tags and states.

=over

=item B<edit_tag>( $tag|[@tags], %params )

=item B<edit_state>( $state|[@states], %params )

Accepts the following parameters.

=over

=item B<share> / B<public>

Make the given tags / states public.

=item B<unshare> / B<private>

Make the given tags / states private.

=item B<disable> / B<delete>

Only tags (and not states) can be disabled.

=back

=item B<share_tag>( @tags )

=item B<unshare_tag>( @tags )

=item B<share_state>( @states )

=item B<unshare_state>( @states )

Associate / unassociate the 'broadcast' state with the given tags / states.

=item B<delete_tag>( @tags )

Delete the given tags.

=item B<rename_feed_tag>( $oldtag|[@oldtags], $newtag|[@newtags]

Renames the tags associated with any feeds.

=item B<rename_entry_tag>( $oldtag|[@oldtags], $newtag|[@newtags]

Renames the tags associated with any individual entries.

=item B<rename_tag>( $oldtag|[@oldtags], $newtag|[@newtags]

Calls B<rename_feed_tag> and B<rename_entry_tag>, and finally B<delete_tag>.

=item B<mark_read_tag>( @tags )

=item B<mark_read_state>( @states )

Marks all entries as read for the given tags / states.

=back

=head2 Edit entries

The following methods are used to edit individual entries.

=over

=item B<edit_entry>( $entry|[@entries], %params )

=over

=item B<tag> / B<state> / B<untag> / B<unstate>

Associate / unassociate the entries with the given tags / states.

=back

=item B<tag_entry>( $entry|[@entries], @tags )

=item B<untag_entry>( $entry|[@entries], @tags )

=item B<state_entry>( $entry|[@entries], @tags )

=item B<unstate_entry>( $entry|[@entries], @tags )

Associate / unassociate the entries with the given tags / states.

=item B<share_entry>( @entries )

=item B<unshare_entry>( @entries )

Marks all the given entries as "broadcast".

=item B<star>

=item B<star_entry>

=item B<unstar>

=item B<unstar_entry>

Marks / unmarks all the given entries as "starred".

=item B<mark_read_entry>( @entries )

Marks all the given entries as "read".

=back

=head2 Miscellaneous

These are a list of other useful methods.

=over

=item B<edit_preference>( $key, $value )

Sets the given preference name to the given value.

=item B<mark_read>( feed => $feed|[@feeds], state => $state|[@states],
                    tag => $tag|[@tags] )

=item B<opml>

Exports feed subscriptions as OPML.

=item B<ping>

Returns true / false on success / failure. Unsure of when this needs to be
used.

=back

=head2 Private methods

The following private methods may be of use to others.

=over

=item B<_login>

This is automatically called from within methods that require authorization.
An optional parameter is accepted which when true, will force a login even
if a previous login was successful. The end result of a successful login is
to set the SID cookie.

=item B<_request>

Given an C<HTTP::Request>, this will perform the request and if the response
indicates a bad (expired) token, it will request another token before
performing the request again. Returns an C<HTTP::Response> on success, false
on failure (check B<error>).

=item B<_token>

This is automatically called from within methods that require a user token.
If successful, the token is available via the B<token> accessor.

=item B<_states>

Returns a list of all the known states. See L</STATES>.

=back

=head1 TAGS

The following characters are not allowed: "E<lt>E<gt>?&/\^

=head1 STATES

These are tags in a Google-specific namespace. The following are all the known
used states.

=over

=item read

Entries which have been read.

=item kept-unread

Entries which have been read, but marked unread.

=item fresh

New entries from reading-list.

=item starred

Entries which have been starred.

=item broadcast

Entries which have been shared and made publicly available.

=item reading-list

Entries from all subscriptions.

=item tracking-body-link-used

Entries for which a link in the body has been clicked.

=item tracking-emailed

Entries which have been mailed.

=item tracking-item-link-used

Entries for which the title link has been clicked.

=item tracking-kept-unread

Entries which have been kept unread.
(Not sure how this differs from "kept-unread").

=back

=head1 NOTES

If C<Compress::Zlib> is found, then requests will accept compressed responses.

=head1 SEE ALSO

L<XML::Atom::Feed>

L<http://code.google.com/p/pyrfeed/wiki/GoogleReaderAPI>

=head1 REQUESTS AND BUGS

Please report any bugs or feature requests to
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=WebService-Google-Reader>.
I will be notified, and then you'll automatically be notified of progress on
your bug as I make changes.

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
