#!/usr/bin/perl

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

use Cairo;
use slog;
use Getopt::Long;
use POSIX qw(strftime);

my $w = 300;
my $h = 60;
my $start;
my $end;
my $outfile = 'out.png';

GetOptions(
  'width|w=i' => \$w,
  'height|h=i' => \$h,
  'start|s=i' => \$start,
  'end|e=i' => \$end,
  'out|o=s' => \$outfile,
);

my @slogs = @ARGV;

if(!@slogs) {
  print "must specify some slog files!\n";
  exit 1;
}

if(!defined($start) || !defined($end)) {
  ($estart, $eend) = find_extents($start, $end, @slogs);
  if(!defined($start)) {
    $start = $estart;
    print "WARNING: set start to " . strftime('%Y-%m-%d %H:%M:%S', localtime($start)) . "\n";
  }
  if(!defined($end)) {
    $end = $eend;
    print "WARNING: set end to " . strftime('%Y-%m-%d %H:%M:%S', localtime($end)) . "\n";
  }
}

# set up a cairo surface
my $s = Cairo::ImageSurface->create('argb32', $w, $h);
my $c = Cairo::Context->create($s);
$c->set_antialias('none');

# cleaner "sparkline": rows color coded by status over time
origin_status_sparkline2($s, $c, $w, $h, $start, $end, @slogs);

# less clean "sparkline": rows per kind of status at various heights
#my ($valid_pops, $data) = join_origin_slogs($start, $end, \@slogs);
#my $N = @slogs;
#origin_status_sparkline($s, $c, $data, $start, $end, $N, $w, $h);

$s->write_to_png($outfile);


sub find_extents
{
  my ($start, $end, @slogs) = @_;
  foreach my $path (@slogs) {
    my $slog = slog->new($path);
    next unless $slog->open();
    my $data = $slog->fetch();
    if(!defined($start) || $data->[0]->[0] < $start) {
      $start = $data->[0]->[0];
    }
    if(!defined($end) || $data->[@$data-1]->[0] > $end) {
      $end = $data->[@$data-1]->[0];
    }
  }
  return ($start, $end);
}

sub origin_status_sparkline2
{
  my ($surface, $cairo, $w, $h, $start, $end, @slogs) = @_;

  my $colors = {
    'up' =>      [0.13, 0.8, 0.13],
    'down' =>    [1.0, 0.27, 0],
    'nodns' =>   [0.27, 0.51, 0.71],
    'unknown' => [1.0, 0.84, 0]
  };

  $cairo->rectangle(0, 0, $w, $h);
  $unk = $colors->{'unknown'};
  $cairo->set_source_rgb($unk->[0], $unk->[1], $unk->[2]);
  $cairo->fill;

  my $len = $end - $start;
  my $rowheight = $h/@slogs;
  my $row = 0;

  foreach my $path (@slogs) {
    my $slog = slog->new($path);
    next unless $slog->open();
    my $data = $slog->fetch($start, $end);

    # move the first data point to the start (it may have been earlier
    # and not changed until after the start)
    if($data->[0]->[0] < $start && (@$data == 1 || $data->[1]->[0] > $start)) {
      $data->[0]->[0] = $start;
    }

    # add a last data point at the end
    if($data->[@$data-1]->[0] < $end) {
      push @$data, [$end, 'unknown'];
    }

    my $yi = $row * $rowheight;
    my $xi = 0;
    for(my $i = 0; $i < @$data-1; ++$i) {
      my $ts = $data->[$i]->[0];
      my $value = $data->[$i]->[1];
      if(!defined($value)) { $value = 'unknown'; }
      my $color = $colors->{$value};
      my $dt = $data->[$i+1]->[0] - $ts;
      my $wi = $w * $dt/$len;
      $cairo->rectangle($xi, $yi, $wi, $rowheight);
      $cairo->set_source_rgb($color->[0], $color->[1], $color->[2]);
      $cairo->fill;
      $xi += $wi;
    }
    ++$row;
  }
}


sub join_origin_slogs
{
  my ($start, $end, $paths) = @_;
  my (@full, @times);
  my $valid_pops = 0;
  foreach my $path (@$paths) {
    my $slog = slog->new($path);
    next unless $slog->open();
    ++$valid_pops;
    my $raw = $slog->fetch($start, $end);
    push @full, $raw;
    foreach my $dp (@$raw) {
      push @times, ${@$dp}[0];
    }
  }

  my $data = [];
  foreach my $ts (sort @times) {
    my %dp = ('up' => 0, 'down' => 0, 'nodns' => 0, 'unknown' => 0);
    my $skip = 0;
    foreach my $slog_data (@full) {
      my $val = my_get_value_at_time($slog_data, $ts);
      if(!defined($val)) { $skip = 1; last; }
      $dp{$val}++;
    }
    # skip partial data points (mostly the starts of the slogs)
    next unless !$skip;
    push @$data, [int($ts), $dp{'up'}, $dp{'down'}, $dp{'nodns'}, $dp{'unknown'}];
  }

  return ($valid_pops, $data);
}

sub my_get_value_at_time
{
  my ($sd, $ts) = @_;
  for(my $i = 0; $i < @$sd; ++$i) {
    if(${@$sd}[$i][0] <= $ts && ($i+1 == @$sd || ${@$sd}[$i+1][0] > $ts)) {
      return ${@$sd}[$i][1];
    }
  }
  return undef;
}


# data is an array of 5-d points (ts, #up, #down, #nodns, #unknown)
# start/end are timestamps after/before the extremes in the data, resp.
# N is the maximum value of #up/#down/#nodns/#unknown (i.e., # of pops)
# w/h are dimensions of the output image
sub origin_status_sparkline
{
  my ($surface, $cairo, $data, $start, $end, $N, $w, $h) = @_;

  # no data, we'll do unknown
  if(@$data == 0) {
    ${@$data}[0] = [$start, 0, 0, 0, $N];
  }

  # move the first data point to the start (it may have been earlier
  # and not changed until after the start)
  if(${@$data}[0][0] < $start && (@$data == 1 || ${@$data}[1][0] > $start)) {
    ${@$data}[0][0] = $start;
  }

  # add a last data point at the end
  if(${@$data}[@$data-1][0] < $end) {
    push @$data, [$end, 0, 0, 0, 0];
  }

  my $len = $end - $start;
  my $xi = 0;
  for(my $i = 0; $i < @$data-1; ++$i) {
    my $dt = ${@$data}[$i+1][0] - ${@$data}[$i][0];
    my $wi = $w * $dt/$len;

    # up bar
    my $h_up = -(${@$data}[$i][1] / $N) * ($h/2);
    if($h_up < 0) {
      $cairo->rectangle($xi, $h/2, $wi, $h_up);
      $cairo->set_source_rgb(0.13, 0.8, 0.13);
      $cairo->fill;
    }

    # stack down/nodns/unknown:

    # down bar
    my $h_down = (${@$data}[$i][2] / $N) * ($h/2);
    if($h_down > 0) {
      $cairo->rectangle($xi, $h/2, $wi, $h_down);
      $cairo->set_source_rgb(1.0, 0.27, 0);
      $cairo->fill;
    }

    # nodns bar
    my $h_nodns = (${@$data}[$i][3] / $N) * ($h/2);
    if($h_nodns > 0) {
      $cairo->rectangle($xi, $h/2+$h_down, $wi, $h_nodns);
      $cairo->set_source_rgb(0.27, 0.51, 0.71);
      $cairo->fill;
    }

    # unknown bar
    # add N - (nodns+down+up) to unknown
    ${@$data}[$i][4] += $N - ${@$data}[$i][1] - ${@$data}[$i][2] - ${@$data}[$i][3];
    my $h_unknown = (${@$data}[$i][4] / $N) * ($h/2);
    if($h_unknown > 0) {
      $cairo->rectangle($xi, $h/2+$h_nodns+$h_down, $wi, $h_unknown);
      $cairo->set_source_rgb(1.0, 0.84, 0);
      $cairo->fill;
    }

    $xi += $wi;
  }
}
