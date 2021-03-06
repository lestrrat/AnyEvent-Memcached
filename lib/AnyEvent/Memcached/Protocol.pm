package AnyEvent::Memcached::Protocol;
use Any::Moose;
use namespace::clean -except => qw(meta);

use constant +{
    HAVE_ZLIB => eval { require Compress::Zlib; 1 },
    F_STORABLE => 1,
    F_COMPRESS => 2,
    COMPRESS_SAVINGS => 0.20,
};

has add_cb => (
    init_arg => undef,
    is => 'ro',
    isa => 'CodeRef',
    lazy_build => 1,
);
    
has decr_cb => (
    init_arg => undef,
    is => 'ro',
    isa => 'CodeRef',
    lazy_build => 1,
);

has delete_cb => (
    init_arg => undef,
    is => 'ro',
    isa => 'CodeRef',
    lazy_build => 1,
);

has incr_cb => (
    init_arg => undef,
    is => 'ro',
    isa => 'CodeRef',
    lazy_build => 1,
);

has memcached => (
    is => 'ro',
    isa => 'AnyEvent::Memcached',
    required => 1,
);

has get_cb => (
    init_arg => undef,
    is => 'ro',
    isa => 'CodeRef',
    lazy_build => 1,
);

has get_multi_cb => (
    init_arg => undef,
    is => 'ro',
    isa => 'CodeRef',
    lazy_build => 1,
);

has replace_cb => (
    init_arg => undef,
    is => 'ro',
    isa => 'CodeRef',
    lazy_build => 1,
);

has set_cb => (
    init_arg => undef,
    is => 'ro',
    isa => 'CodeRef',
    lazy_build => 1,
);

has stats_cb => (
    init_arg => undef,
    is => 'ro',
    isa => 'CodeRef',
    lazy_build => 1,
);

sub _build_add_cb {}
sub _build_decr_cb {}
sub _build_delete_cb {}
sub _build_incr_cb {}
sub _build_get_cb {}
sub _build_get_multi_cb {}
sub _build_replace_cb {}
sub _build_set_cb {}
sub _build_stats_cb {}

sub prepare_handle {}

sub get_handle_for {
    my ($self, $key) = @_;
    my $memcached = $self->memcached;
    my $count     = $memcached->get_server_count();
    my $hash      = $memcached->hashing_algorithm->hash($key);
    my $i         = $hash % $count;
    my $handle    = $memcached->get_handle( $memcached->get_server($i) );

    return $handle;
}

sub prepare_value {
    my ($self, $cmd, $value, $exptime) = @_;

    my $memcached = $self->memcached;

    my $flags = 0;
    if (ref $value) {
        $value = Storable::nfreeze($value);
        $flags |= F_STORABLE();
    }

    my $len = bytes::length($value);
    my $threshold = $memcached->compress_threshold;
    my $compressable = 
        ($cmd ne 'append' && $cmd ne 'prepend') &&
        $threshold && 
        HAVE_ZLIB() &&
        $memcached->compress_enabled &&
        $len >= $threshold
    ;
    if ($compressable) {
        my $c_val = Compress::Zlib::memGzip($value);
        my $c_len = length($c_val);

        if ($c_len < $len * ( 1 - COMPRESS_SAVINGS() ) ) {
            $value = $c_val;
            $len = $c_len;
            $flags |= F_COMPRESS();
        }
    }
    $exptime = int($exptime || 0);

    return ($value, $len, $flags, $exptime);
}

sub decode_value {
    my ($self, $flags, $data) = @_;
    if ($flags & F_COMPRESS() && HAVE_ZLIB()) {
        $data = Compress::Zlib::memGunzip($data);
    }
    if ($flags & F_STORABLE()) {
        $data = Storable::thaw($data);
    }
    return $data;
}

__PACKAGE__->meta->make_immutable();

1;

__END__

=head1 NAME

AnyEvent::Memcached::Protocol - Base Class For Memcached Protocol

=head1 SYNOPSIS

    package NewProtocol;
    use Any::Moose;
    extends 'AnyEvent::Memcached::Protocol';

=cut