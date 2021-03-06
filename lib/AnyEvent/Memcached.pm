package AnyEvent::Memcached;
use Any::Moose;
use AnyEvent;
use AnyEvent::Handle;
use AnyEvent::Socket;
use namespace::clean-except => qw(meta);

has compress_enabled => (
    is => 'ro',
    isa => 'Bool',
    default => 1,
);

has compress_threshold => (
    is => 'ro',
    isa => 'Int',
);

has connected => (
    is => 'rw',
    isa => 'Bool',
    default => 0,
);

has drain_watcher => (
    is => 'rw',
    clearer => 'clear_drain_watcher',
);

has handles => (
    is => 'ro',
    isa => 'HashRef',
    writer => 'set_handles',
);

has hashing_algorithm_class => (
    is => 'ro',
    isa => 'Str',
    required => 1,
    default => 'Modula',
    trigger => sub {
        my $self = shift;
        $self->clear_protocol;
    }
);

has hashing_algorithm => (
    is => 'ro',
    isa => 'AnyEvent::Memcached::Hash',
    lazy_build => 1,
);

has is_connecting => (
    is => 'rw',
    isa => 'Bool',
    default => 0,
);

has protocol => (
    is => 'ro',
    isa => 'AnyEvent::Memcached::Protocol',
    lazy_build => 1,
);

has protocol_class => (
    is => 'rw',
    isa => 'Str',
    required => 1,
    default => 'Text',
    trigger => sub {
        my $self = shift;
        $self->clear_protocol;
    }
);

has queue => (
    is => 'ro',
    isa => 'ArrayRef',
    lazy_build => 1,
);

has servers => (
    is => 'ro',
    isa => 'ArrayRef',
    required => 1,
);

sub _build_hashing_algorithm {
    my $self = shift;
    my $class = $self->hashing_algorithm_class;
    if ($class !~ s/^\+//) {
        $class = "AnyEvent::Memcached::Hash::$class";
    }
    if (! Any::Moose::is_class_loaded($class)) {
        Any::Moose::load_class($class);
    }
    $class->new();
}

sub _build_protocol {
    my $self = shift;
    my $class = $self->protocol_class;
    if ($class !~ s/^\+//) {
        $class = "AnyEvent::Memcached::Protocol::$class";
    }
    if (! Any::Moose::is_class_loaded($class)) {
        Any::Moose::load_class($class);
    }
    $class->new( memcached => $self );
}

sub _build_queue { +[] }

# Utilities that I usually get from Moose Native Traits
sub add_handle { shift->handles->{ $_[0] } = $_[1] }
sub all_handles { @{shift->handles} }
sub all_servers { @{shift->servers} }
sub get_handle { shift->handles->{ $_[0] } }
sub get_server { shift->servers->[$_[0]] }
sub get_server_count { scalar @{shift->servers} }
sub push_queue { push @{shift->queue}, $_[0] }
sub next_queue { shift @{shift->queue} }

sub add {
    my $cb = pop @_ if ref $_[-1] eq 'CODE';
    my ($self, $key, $value, $exptime, $noreply) = @_;
    $self->add_to_queue( $self->protocol->add_cb, [ $self->protocol, $self, $key, $value, $exptime, $noreply, $cb ] );
}

sub decr {
    my $cb = pop @_ if ref $_[-1] eq 'CODE';
    my ($self, $key, $value) = @_;
    $self->add_to_queue( $self->protocol->decr_cb, [ $self->protocol, $self, $key, $value, $cb ] );
}

*remove = \&delete;
sub delete {
    my $cb = pop @_ if ref $_[-1] eq 'CODE';
    my ($self, $key) = @_;
    my $noreply = defined $cb ? 0 : 1;
    $self->add_to_queue( $self->protocol->delete_cb, [ $self->protocol, $self, $key, $noreply, $cb ] );
}

sub get {
    my $cb = pop @_ if ref $_[-1] eq 'CODE';
    my ($self, @keys) = @_;
    $self->add_to_queue( $self->protocol->get_multi_cb, [ $self->protocol, $self, \@keys, $cb, sub { $_[0]->(values %{$_[1]}) } ] );
}

sub get_multi {
    my $cb = pop @_ if ref $_[-1] eq 'CODE';
    my ($self, @keys) = @_;
    $self->add_to_queue( $self->protocol->get_multi_cb, [ $self->protocol, $self, \@keys, $cb, sub { $_[0]->($_[1]) } ] );
}

sub incr {
    my $cb = pop @_ if ref $_[-1] eq 'CODE';
    my ($self, $key, $value) = @_;
    $self->add_to_queue( $self->protocol->incr_cb, [ $self->protocol, $self, $key, $value, $cb ] );
}

sub replace {
    my $cb = pop @_ if ref $_[-1] eq 'CODE';
    my ($self, $key, $value, $exptime, $noreply) = @_;
    $self->add_to_queue( $self->protocol->replace_cb, [ $self->protocol, $self, $key, $value, $exptime, $noreply, $cb ] );
}

sub set {
    my $cb = pop @_ if ref $_[-1] eq 'CODE';
    my ($self, $key, $value, $exptime, $noreply) = @_;
    $self->add_to_queue( $self->protocol->set_cb, [ $self->protocol, $self, $key, $value, $exptime, $noreply, $cb ] );
}

sub stats {
    my $cb = pop @_ if ref $_[-1] eq 'CODE';
    my ($self, $name) = @_;
    $self->add_to_queue( $self->protocol->stats_cb, [ $self->protocol, $self, $name, $cb ] );
}

sub add_to_queue {
    my ($self, $cb, $args) = @_;
    $self->push_queue( [ $cb, $args ] );
    if (! $self->drain_watcher) {
        my $w; $w = AE::timer 0, 0, sub {
            $self->clear_drain_watcher();
            $self->drain_queue
        };
        $self->drain_watcher($w);
    }
}

sub connect {
    my $self = shift;
    $self->is_connecting(1);
    my %handles;
    my $cv = AE::cv {
        $self->set_handles( \%handles );
        $self->is_connecting(0);
        $self->connected(1);
        $self->drain_queue();
    };
    foreach my $server ( $self->all_servers ) {
        $cv->begin;
        my ($host, $port) = split(/:/, $server);
        $port ||= 11211;
        my $guard; $guard = tcp_connect $host, $port, sub {
            my ($fh, $host, $port) = @_;

            undef $guard;
            my $h; $h = AnyEvent::Handle->new(
                fh => $fh,
                on_error => sub { warn "error"; undef $h },
                on_eof   => sub { warn "eof"; undef $h },
            );

            $self->protocol->prepare_handle( $fh );
            $handles{ $server } = $h;
            $cv->end;
        };
    }
}

sub drain_queue {
    my $self = shift;

    if( ! $self->connected ) {
        return if $self->is_connecting;
        $self->connect;
        return;
    }

    my $next = $self->next_queue;
    if ($next) {
        my ($cb, $args) = @$next;
        $cb->(@$args);
    }
}

sub destroy {
    my $self = shift;
    foreach my $handle ( $self->all_handles ) {
        $handle->destroy;
    }
    $self->clear_handles();
}

sub DEMOLISH {
    my $self = shift;
    $self->destroy;
}

1;

__END__

=head1 NAME

AnyEvent::Memcached - AnyEvent Memcached Client

=head1 SYNOPSIS

    use AnyEvent::Memcached;
    my $memd = AnyEvent::Memcached->new(
        servers => [ '127.0.0.1:11211' ],
        compress_threshold => 10_000,
    );
    $memd->get( $key, $cb->($value) );
    $memd->set( $key, $value, $exptime, $cb->($success) );
    $memd->delete( $key, $cb->($success) );
    $memd->get_multi( @list_of_keys, $cb->(\%values) );
    $memd->stats( $name, $cb->(\%stats) );

    # using the binary protocol
    my $memd = AnyEvent::Memcached->new(
        protocol_class => 'Binary',
        servers => [ '127.0.0.1:11211' ],
        compress_threshold => 10_000
    );

    # using your custom (OMG!) protocol
    my $memd = AnyEvent::Memcached->new(
        protocol => MyProtocol->new(),
        servers => [ '127.0.0.1:11211' ],
        compress_threshold => 10_000
    );

    # using a different hash algorithm
    my $memd = AnyEvent::Memcached->new(
        hashing_algorithm => MyHasher->new(),
        servers => [ '127.0.0.1:11211' ],
        compress_threshold => 1,
    );

=head1 DESCRIPTION

This module implements a memcached client that resembles the Cache::Memcached
API, except none of the methods return any meaningful value: you need to
specify callbacks to handle them, which will be called via AnyEvent when
the appropriate responses have arrived

=cut
