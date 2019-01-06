use strict;
use warnings;
use Path::Tiny;
use Promise;
use Promised::Flow;
use Promised::File;
use Web::URL;
use JSON::PS;
use Web::Transport::BasicClient;

my $DataPath = path (__FILE__)->parent->parent->child ('data');

sub with_retry ($) {
  my $code = shift;
  my $return;
  my $n = 0;
  return ((promised_wait_until {
    return Promise->resolve->then ($code)->then (sub {
      $return = $_[0];
      return 'done';
    }, sub {
      my $e = $_[0];
      die $e if $n++ > 5;
      warn "Failed ($e); retrying ($n)...\n";
      return not 'done';
    });
  })->then (sub {
    return $return;
  }));
} # with_retry

sub validate_name ($) {
  my $name = shift;
  die "Unexpected name |$name|" unless $name =~ m{\A[0-9A-Za-z\@_-]+\z};
} # validate_name

sub save_entries ($$) {
  my ($type, $items) = @_;
  return promised_for {
    my $item = shift;

    validate_name $item->{user}->{screen_name};
    validate_name $item->{id};
    validate_name $item->{tld};
    
    my $path = $DataPath->child ('users')
        ->child ($item->{user}->{screen_name} . '.' . $item->{tld})
        ->child ($item->{id} . '.' . $type . '.json');
    my $file = Promised::File->new_from_path ($path);

    return $file->is_file->then (sub {
      return if $_[0]; # skip
      return $file->write_byte_string (perl2json_bytes $item);
    });
  } $items;
} # save_entries

sub get ($%) {
  my ($type, %args) = @_;
  my $client = Web::Transport::BasicClient->new_from_url
      (Web::URL->parse_string ("http://h.hatena.ne.jp"));
  my $tld = 'jp'; # XXX
  my $page = 1;
  return ((promised_until {
    return with_retry (sub {
      return $client->request (
        path => [
          'api', 'statuses',
          ($type eq 'user' ? ($type . '_timeline', $args{name} . '.json')
                           : ($type . '_timeline.json')),
        ],
        params => {
          body_formats => 'haiku',
          count => 200,
          page => $page,
        },
      )->then (sub {
        my $res = $_[0];
        die $res unless $res->status == 200;
        return json_bytes2perl $res->body_bytes;
      });
    })->then (sub {
      my $json = $_[0];
      if (ref $json eq 'ARRAY') {
        return 'done' unless @$json;
        
        $_->{tld} = $tld for @$json;
        return Promise->all ([
          save_entries ('h', $json),
        ])->then (sub {
          return 'done' if $page++ > 100;
          print STDERR "*";
          return not 'done';
        });
      } else {
        die "Server returns an unexpected response";
      }
    });
  })->finally (sub {
    return $client->close;
  }));
} # get

sub main (@) {
  my $command = shift // '';
  if ($command eq 'user') {
    my $name = shift // '';
    die "Usage: har user name" unless length $name;
    get ('user', name => $name)->to_cv->recv;
  } elsif ($command eq 'public') {
    get ('public')->to_cv->recv;
  } else {
    die "Usage: har command\n";
  }
} # main

main (@ARGV);

=head1 LICENSE

Copyright 2019 Wakaba <wakaba@suikawiki.org>.

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as
published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
Affero General Public License for more details.

You should have received a copy of the GNU Affero General Public
License along with this program.  If not, see
<https://www.gnu.org/licenses/>.

=cut
