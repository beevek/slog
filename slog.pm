package slog;

#   Copyright 2008-2013 Kristopher R Beevers and Internap Network
#   Services Corporation.

#   Permission is hereby granted, free of charge, to any person
#   obtaining a copy of this software and associated documentation files
#   (the "Software"), to deal in the Software without restriction,
#   including without limitation the rights to use, copy, modify, merge,
#   publish, distribute, sublicense, and/or sell copies of the Software,
#   and to permit persons to whom the Software is furnished to do so,
#   subject to the following conditions:

#   The above copyright notice and this permission notice shall be
#   included in all copies or substantial portions of the Software.

#   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
#   EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
#   MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
#   NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
#   BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
#   ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
#   CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
#   SOFTWARE.


# an "RRD-like" mechanism for storing "diff logs" --- basically log
# entries indicating status changes.  it uses a sqlite backend.  
# whenever an update occurs, it is _only_ stored in the database if 
# there is a change from the preceding log entry.

# the sqlite db contains two tables:

# meta: length (in seconds), columns --- length is max time to keep
# log entries; columns is the set of column names (each entry must
# have exactly this set of columns)

# log data: timestamp, column 1, ..., column n --- column values are
# up to the user


use Carp;
use DBI;

sub new
{
    my ($class, $path) = @_;

    croak "error: no path specified in slog::new" unless defined($path);

    my $self = bless {}, $class;
    $self->{path} = $path;

    return $self;
}

sub open
{
    my ($self) = @_;

    return 0 unless -f $self->{path};

    $self->{db} = DBI->connect("dbi:SQLite:dbname=$self->{path}",'','');
    return 0 unless $self->{db};

    # get metadata
    my $sth = $self->{db}->prepare('SELECT name, value FROM meta');
    $sth->execute();
    while(my $row = $sth->fetch()) {
      $self->{$row->[0]} = $row->[1];
    }
    return 1;
}

sub create
{
    my ($self, $length, @columns) = @_;

    croak "error: no columns specified in slog::create" unless @columns;

    $self->{db} = DBI->connect("dbi:SQLite:dbname=$self->{path}",'','');
    return 0 unless $self->{db};

    $self->{num_columns} = @columns+1;
    my $cols = join(' TEXT, ', @columns).' TEXT';

    return 0 unless
	$self->{db}->do('CREATE TABLE meta(name TEXT, value TEXT)') &&
	$self->{db}->do('CREATE TABLE logs(timestamp INTEGER, '.$cols.')') &&
	$self->{db}->do('CREATE INDEX index_timestamp ON logs(timestamp)') &&
	$self->{db}->do("INSERT INTO meta VALUES ('length','$length')") &&
	$self->{db}->do("INSERT INTO meta VALUES ('num_columns','$self->{num_columns}')");

    return 1;
}

sub current
{
    my ($self, @columns) = @_;
    my $what = @columns == 0 ? '*' : join(',', @columns);
    my $sth = $self->{db}->prepare('SELECT '.$what.' FROM logs ORDER BY ROWID DESC LIMIT 1');
    return undef unless $sth->execute();
    my $row = $sth->fetch();
    return @$row;
}

sub update
{
    my ($self, @dp) = @_;

    if(@dp != $self->{num_columns}) {
	warn "warning: datapoint must contain exactly $self->{num_columns} values";
	return 0;
    }

    # 1. verify that the update ts is newer than the most recent in
    # the db
    my @current = $self->current();
    my ($ts, $cur_ts) = (shift @dp, shift @current);
    if(defined($cur_ts) && $cur_ts >= $ts) {
	warn "warning: discarding update for time $ts, which isn't newer than $cur_ts";
	return 0;
    }

    # 2. insert new ONLY if different than current
    my $ok = @current ? 0 : 1;
    for(my $i = 0; $i < @current; ++$i) {
	if($current[$i] ne $dp[$i]) {
	    $ok = 1;
	    last;
	}
    }
    if($ok) {
	my $cols = '';
	foreach my $p (@dp) { $cols .= "'$p',"; }
	chop $cols;
	my $sth = $self->{db}->prepare("INSERT INTO logs VALUES($ts, $cols)");
	return 0 unless $sth->execute();
    } else { # update the file's mtime anyway just so we know it's up to date
	my $now = time();
	utime $now, $now, $self->{path};
    }
    $cur_ts = $ts;

    # 3. delete anything too old from the db
    my $too_old = $cur_ts - $self->{length};
    my $sth = $self->{db}->prepare("DELETE FROM logs WHERE timestamp < $too_old");
    return 0 unless $sth->execute();

    return 1;
}

# fetch @columns between $start to $end, including whatever the value
# was at $start; also handle if $start = undef or $end = undef
sub fetch
{
    my ($self, $start, $end, @columns) = @_;
    my $what = @columns == 0 ? '*' : join(',', @columns);
    my @ret = ();

    # if there's a start time, get the value at that time first
    if(defined($start)) {
	push @ret, [$self->value_at_time($start, @columns)];
    }

    # now get subsequent entries
    my $query = "SELECT $what FROM logs";
    if(defined($start) || defined($end)) {
	$query .= ' WHERE ';
	$query .= "timestamp >= $start" if defined($start);
	$query .= ' AND ' if(defined($start) && defined($end));
	$query .= "timestamp <= $end" if defined($end);
    }

    my $sth = $self->{db}->prepare($query);
    return undef unless $sth->execute();
    while(my $row = $sth->fetch()) { my @copy = @$row; push @ret, [@copy]; }
    return \@ret;
}

# figure out the values of @columns (or all columns if @columns =
# undef) at the given timestamp
sub value_at_time
{
    my ($self, $ts, @columns) = @_;
    my $what = @columns == 0 ? '*' : join(',', @columns);
    my $sth = $self->{db}->prepare
	('SELECT '.$what.' FROM logs WHERE timestamp <= '.
	 $ts.' ORDER BY ROWID DESC LIMIT 1');
    return undef unless $sth->execute();
    my $row = $sth->fetch();
    return @$row;
}


1;
__END__
