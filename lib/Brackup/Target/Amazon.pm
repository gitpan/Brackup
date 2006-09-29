package Brackup::Target::Amazon;
use strict;
use warnings;
use base 'Brackup::Target';
use Net::Amazon::S3 0.31;
use DBD::SQLite;

# fields in object:
#   s3  -- Net::Amazon::S3
#   dbh -- sqlite dbi exist cache
#   access_key_id
#   sec_access_key_id
#   chunk_bucket : $self->{access_key_id} . "-chunks";
#   backup_bucket : $self->{access_key_id} . "-backups";
#

sub new {
    my ($class, $confsec) = @_;
    my $self = bless {}, $class;

    if (my $cache_file = $confsec->value("exist_cache")) {
        $self->{dbh} = DBI->connect("dbi:SQLite:dbname=$cache_file","","", { RaiseError => 1, PrintError => 0 }) or
            die "Failed to connect to SQLite filesystem digest cache database at $cache_file: " . DBI->errstr;

        eval {
            $self->{dbh}->do("CREATE TABLE amazon_key_exists (key TEXT PRIMARY KEY, value TEXT)");
        };
        die "Error: $@" if $@ && $@ !~ /table amazon_key_exists already exists/;
    }

    $self->{access_key_id}     = $confsec->value("aws_access_key_id")
        or die "No 'aws_access_key_id'";
    $self->{sec_access_key_id} = $confsec->value("aws_secret_access_key")
        or die "No 'aws_secret_access_key'";

    $self->_init_common;

    my $s3      = $self->{s3};
    my $buckets = $s3->buckets or die "Failed to get bucket list";

    unless (grep { $_->{bucket} eq $self->{chunk_bucket} } @{ $buckets->{buckets} }) {
        $s3->add_bucket({ bucket => $self->{chunk_bucket} })
            or die "Chunk bucket creation failed\n";
    }

    unless (grep { $_->{bucket} eq $self->{backup_bucket} } @{ $buckets->{buckets} }) {
        $s3->add_bucket({ bucket => $self->{backup_bucket} })
            or die "Backup bucket creation failed\n";
    }

    return $self;
}

sub _init_common {
    my $self = shift;
    $self->{chunk_bucket}  = $self->{access_key_id} . "-chunks";
    $self->{backup_bucket} = $self->{access_key_id} . "-backups";
    $self->{s3}            = Net::Amazon::S3->new({
        aws_access_key_id     => $self->{access_key_id},
        aws_secret_access_key => $self->{sec_access_key_id},
    });
}

# ghetto
sub _prompt {
    my ($q) = @_;
    print "$q";
    my $ans = <STDIN>;
    $ans =~ s/^\s+//;
    $ans =~ s/\s+$//;
    return $ans;
}

sub new_from_backup_header {
    my ($class, $header) = @_;

    my $accesskey     = ($ENV{'AWS_KEY'} || _prompt("Your Amazon AWS access key? "))
        or die "Need your Amazon access key.\n";
    my $sec_accesskey = ($ENV{'AWS_SEC_KEY'} || _prompt("Your Amazon AWS secret access key? "))
        or die "Need your Amazon secret access key.\n";

    my $self = bless {}, $class;
    $self->{access_key_id}     = $accesskey;
    $self->{sec_access_key_id} = $sec_accesskey;
    $self->_init_common;
    return $self;
}

sub has_chunk {
    my ($self, $chunk) = @_;
    my $dig = $chunk->backup_digest;   # "sha1:sdfsdf" format scalar

    if (my $dbh = $self->{dbh}) {
        my $ans = $dbh->selectrow_array("SELECT COUNT(*) FROM amazon_key_exists WHERE key=?", undef, $dig);
        return 1 if $ans;
    }

    my $res = eval { $self->{s3}->head_key({ bucket => $self->{chunk_bucket}, key => $dig }); };
    return 0 unless $res;
    return 0 if $@ && $@ =~ /key not found/;
    return 0 unless $res->{content_type} eq "x-danga/brackup-chunk";
    $self->_cache_existence_of($dig);
    return 1;
}

sub load_chunk {
    my ($self, $dig) = @_;
    my $bucket = $self->{s3}->bucket($self->{chunk_bucket});

    my $val = $bucket->get_key($dig)
        or return 0;
    return \ $val->{value};
}

sub store_chunk {
    my ($self, $chunk) = @_;
    my $dig = $chunk->backup_digest;
    my $blen = $chunk->backup_length;
    my $len = $chunk->length;

    my $rv = eval { $self->{s3}->add_key({
        bucket        => $self->{chunk_bucket},
        key           => $dig,
        value         => ${ $chunk->chunkref },
        content_type  => 'x-danga/brackup-chunk',
    }) };
    return 0 unless $rv;
    $self->_cache_existence_of($dig);
    return 1;
}

sub _cache_existence_of {
    my ($self, $dig) = @_;
    if (my $dbh = $self->{dbh}) {
        $dbh->do("INSERT INTO amazon_key_exists VALUES (?,1)", undef, $dig);
    }
}

sub store_backup_meta {
    my ($self, $name, $file) = @_;

    my $rv = eval { $self->{s3}->add_key({
        bucket        => $self->{backup_bucket},
        key           => $name,
        value         => $file,
        content_type  => 'x-danga/brackup-meta',
    })};

    return $rv;
}

1;
