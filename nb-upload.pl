#!/usr/bin/perl

use strict;
use warnings;

use WWW::Mechanize;
use File::Basename;
use File::Find;
use NFOStripper;
use Getopt::Long; # to handle arguments
Getopt::Long::Configure ('bundling');
use Config::Simple;
use Convert::Bencode qw(bencode bdecode);
use JSON;
use URI::URL;
use XML::Simple;
use Image::Imgur;

## EDIT BELOW:::: ##

# Handle config.
my $config_file = $ENV{"HOME"}."/.nb-upload.cfg";
my $cfg = new Config::Simple();
$cfg->read($config_file) or die "CONFIG ERROR: ".$cfg->error();

# Ditt brukernavn og passord på NB
my $username = $cfg->param('username');
my $password = $cfg->param('password');

# Hvor torrent som laget blir lagt
my $torrent_file_dir = $cfg->param('torrent_file_dir');

# Hvor torrents blir lastet ned (rTorrent watch dir)
my $torrent_auto_dir = $cfg->param('torrent_auto_dir');

my $site_url = $cfg->param('site_url');

my $apikey;
if ($cfg->param('use_tmdb') eq "yes") {
	$apikey = $cfg->param('api_key');
}
my $imgurkey;
my $use_tvdb = $cfg->param('use_tvdb');
if ($use_tvdb eq "yes") {
	if ($cfg->param('imgur_key')) {
		$imgurkey = $cfg->param('imgur_key');
	} else {
		$use_tvdb = "no";
	}
}


### DO NOT EDIT BELOW THIS LINE UNLESS YOU KNOW WHAT YOU ARE DOING ####
#######################################################################

my $loginurl = $site_url."/takelogin.php";
my $loginref = $site_url."/hei.php";

my $upload_form = $site_url."/upload.php";

my $rnfo = "";
my $nfo_file = "";

my ($scene, $type);
GetOptions ('s|scene' => \$scene, 't|type=s' => \$type) or die("Wrong input");

if ($scene) {
        $scene = "yes";
} else {
		# always scene from usenet
        $scene = "yes";
}

#indata
my ($path, $release, $is_dir);

sub init1 {
	$path = shift;
	$release = basename($path);

	$is_dir = 0;
	$rnfo = "";
	$nfo_file = "";


	if (-d $path) {
	        $is_dir = 1;
	} else {
	        $release =~ m/.*(\..*)$/;
	        $release =~ s/$1//;
	}
}

# Create Mechanize
my $mech = WWW::Mechanize->new();

sub trim($)
{
	my $string = shift;
	$string =~ s/^\s+//;
	$string =~ s/\s+$//;
	return $string;
}

sub login {
        #print "Logging in...\n";
        $mech->default_header('Referer' => $loginref);
        $mech->post( $loginurl, [ "username" => $username, "password" => $password ] );
	if ($mech->uri eq $site_url."/takelogin.php") { die("Login failed"); }
}

sub create_torrent {
        system("buildtorrent -q -p1 -a http://jalla.com $path $torrent_file_dir/$release.torrent");
        return $torrent_file_dir."/".$release.".torrent";
}

sub upload {
        my ($torrent, $nfo, $descr, $type) = @_;
        #print "Uploading torrent...\n";
        $mech->get($upload_form);
        #print $mech->content;
        $mech->submit_form(
                form_name => "upload",
                fields => {
                       MAX_FILE_SIZE => "3000000",
                       file => $torrent,
                       filetype => "2",
                       name => $release,
                       nfo => $nfo,
                       scenerelease => $scene,
                       descr => $descr,
                       type => $type,
                       anonym => "yes"
                }
        );
        unless ($mech->success) {die("Could not upload");}
        #print $mech->content;
	my $uri = $mech->uri();
	if ($uri =~ /details\.php/) {
		return $uri;
	} else {
		if ($mech->content =~ /<h3>Mislykket\sopplasting!<\/h3>\n<p>(.*)<\/p>/) {
			#print $1."\n";
		}
		die("Upload failed!");
	}
}

sub download_torrent {
        my $uri = shift;
        #print "Downloading torrent...\n";
        $mech->get($uri);
        $mech->follow_link( url_regex => qr/download/i );
        unless($mech->success) {die("Could not download torrent");}
        open(my $TORFILE, ">", $torrent_auto_dir."/".$release.".torrent") || die("Could not open file: $!");
        #print $TORFILE $mech->content;
		my $tfile = fast_resume($mech->content);
		print $TORFILE $tfile;
        close($TORFILE);
        return $uri;
}

sub fast_resume {
	my $t = bdecode(shift);
	
	#$log->info("applying fast-resume");
	
	my $d = $path;
	$d =~ s/$release//;
	#$d .= "/" unless $d =~ m#/$#;
	
	#die "No info key.\n" unless ref $t eq "HASH" and exists $t->{info};
	unless (ref $t eq "HASH" and exists $t->{info}) {
		#$log->error("fast-resume: No info key");
		die "No info key.\n";
	}
	
	#my $psize = $t->{info}{"piece length"} or die "No piece length key.\n";
	my $psize;
	if($t->{info}{"piece length"}) {
		$psize = $t->{info}{"piece length"};
	} else {
		#$log->error("fast-resume: No piece length key");
		die "No piece length key.\n";
	}

	my @files;
	my $tsize = 0;
	if (exists $t->{info}{files}) {
		#print STDERR "Multi file torrent: $t->{info}{name}\n";
		#$log->info("Multi file torrent: $t->{info}{name}");
		for (@{$t->{info}{files}}) {
			push @files, join "/", $t->{info}{name},@{$_->{path}};
			$tsize += $_->{length};
		}
	} else {
		#print STDERR "Single file torrent: $t->{info}{name}\n";
		#$log->info("Single file torrent: $t->{info}{name}");
		@files = ($t->{info}{name});
		$tsize = $t->{info}{length};
	}
	my $chunks = int(($tsize + $psize - 1) / $psize);
	#$log->info("Fast-resume info: Total size: $tsize bytes; $chunks chunks; ", scalar @files, " files.\n");
	
	#die "Inconsistent piece information!\n" if $chunks*20 != length $t->{info}{pieces};
	if ($chunks*20 != length $t->{info}{pieces}) {
		#$log->error("Inconsistent piece information!");
		die "Inconsistent piece information!\n";
	}
	
	$t->{libtorrent_resume}{bitfield} = $chunks;
	for (0..$#files) {
		#die "$d$files[$_] not found.\n" unless -e "$d$files[$_]";
		unless (-e "$d$files[$_]") {
			#$log->error("$d$files[$_] not found.");
			die "$d$files[$_] not found.\n";
		}
		my $mtime = (stat "$d$files[$_]")[9];
		$t->{libtorrent_resume}{files}[$_] = { priority => 2, mtime => $mtime };
	};
	#$log->info("Fast resume applied");
	
	return bencode $t;
}

sub strip_nfo {
	if ($_ =~ m/.*\.nzb$/) {
		my $nzb = $File::Find::name;
		system("rm -f $nzb");
	}
	
        if ($_ =~ m/.*\.nfo$/) {
                local $/=undef;
                $nfo_file = $File::Find::name;
                open(my $NFO, $nfo_file) || die("Could not open nfo: $!");
                my $filesize = -s $nfo_file;
                read($NFO, my $rawdata, $filesize);
                close($NFO);

                # NFOStripper Object
                my $snfo = eval { new NFOStripper($rawdata); } or die("Could not strip nfo: $!");

                # Set Image Conversion
                $snfo->ImgOpt(0);

                # Set Code Formatting
                $snfo->FormatOpt(0);

                my $result = $snfo->Strip();

                # Remove add.
                my @nfoarr = split(/\n/, $result);
                $result = '[pre]';
                foreach (@nfoarr) {
                       unless ($_ =~ m/Advanced\sNFO\sStripper/) {
                        $result .= $_."\n";
                       }
                }
				$result .= '[/pre]';
				if ($cfg->param('use_tmdb') eq "yes") {
					if($result =~ /(tt\d{7})/) {
						$mech->get('http://api.themoviedb.org/2.1/Movie.getImages/en/json/'.$apikey.'/'.$1);
						#$log->info("imdb link found, trying to get poster");
						if ($mech->success) {
							#$log->info("");
							my $json = JSON->new->utf8(0)->decode($mech->content);
							unless($json->[0] eq "Nothing found.") {
								$rnfo = '[imgw]'.$json->[0]->{'posters'}[0]->{'image'}->{'url'}.'[/imgw]'."\n";
							}
						} else {
							#$log->warn("unable to access themoviedb");
						}
					}
				}
				if ($cfg->param('use_tvdb') eq "yes") {
					if($release =~ /^(.*).S\d{1,}E?\d{0,}/) {
						my $show = $1;
						$show =~ s/\./ /g;
						$mech->get('http://www.thetvdb.com/api/GetSeries.php?seriesname='.rawurlencode($show).'&language=no');
						if($mech->success) {
							my $xml = new XML::Simple;
							my $data = $xml->XMLin($mech->content, ForceArray => 1);
							if($data->{'Series'}[0]->{'banner'}[0]) {
								my $tvdburl = 'http://thetvdb.com/banners/'.$data->{'Series'}[0]->{'banner'}[0];
								my $imgur = new Image::Imgur(key => $imgurkey);
								my $imgururl = $imgur->upload($tvdburl);
								$rnfo = '[img]'.$imgururl.'[/img]'."\n";
							}
						}
					}
				}
                $rnfo .= $result;
				$result =~ s/nedlasting\.net//ig; # nedlasting sux
        }
}

sub rawurlencode {
	my $unencoded_url = shift;
	my $url = URI::URL->new($unencoded_url);
	return $url->as_string;
}

sub find_type {
        #my $release = shift;
        if ($type) { return $type }
        #if ($release =~ m/(BluRay|Blu-Ray)/i) { return "14" }
        if ($release =~ m/(PDTV|HDTV)\.XviD/i) { return "1" }
        if ($release =~ m/(PDTV|HDTV)\.x264/i) { return "29" }
        if ($release =~ m/S\d.*(PAL|NTSC)\.DVDR/i) { return "27" }
        if ($release =~ m/(PAL|NTSC)\.DVDR/i) { return "20" }
        if ($release =~ m/x264/i) { return "28" }
        if ($release =~ m/XviD/i) { return "25" }
        if ($release =~ m/MP4/i) { return "26" }
        if ($release =~ m/MPEG/i) { return "24" }
		
		# Use if not found.
		return "1";

        die("Unable to detect type, try -t|--type");
}

init1($ARGV[0]);
init2();

sub init2 {
	if($is_dir) {
	        find (\&strip_nfo, $path);
	} else {
		return;
	}

	login();

	my $link = "";
	if($nfo_file && $rnfo) {
	        $link = download_torrent(upload(create_torrent(), $nfo_file, $rnfo, find_type()));
	} else {
	        system("echo \"NFO mangler......\" > $path/mangler.nfo");
			init2();
	}
}
