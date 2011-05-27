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
use Log::Log4perl qw(get_logger);
use URI::URL;
#use JSON;
use URI::URL;
#use XML::Simple;
use Cwd 'abs_path';
use utf8;
#use Image::Imgur;
#use Image::Thumbnail;
#use if $cfg->param('use_generator') eq "yes", Net::BitTorrent::Torrent::Generator;

# Handle config.
my $config_file = $ENV{"HOME"}."/.nb-upload.cfg";
my $cfg = new Config::Simple();
$cfg->read($config_file) or die "CONFIG ERROR: ".$cfg->error();

# Initialize perl logging (Not IRC log)
Log::Log4perl::init($config_file);
my $log = Log::Log4perl->get_logger("nb-upload::Log");

# Ditt brukernavn og passord på NB
my $username = $cfg->param('username');
my $password = $cfg->param('password');

# Hvor torrent som laget blir lagt
my $torrent_file_dir = $cfg->param('torrent_file_dir');

# Hvor torrents blir lastet ned (rTorrent watch dir)
my $torrent_auto_dir = $cfg->param('torrent_auto_dir');

my $site_url = $cfg->param('site_url');

my $apikey;
my $use_tmdb;
if ($cfg->param('use_tmdb') eq "yes" and $cfg->param('api_key')) {
	$apikey = $cfg->param('api_key');
	$use_tmdb = "yes";
}
my $imgurkey;
my $use_tvdb = $cfg->param('use_tvdb');
if ($use_tvdb eq "yes") {
	if ($cfg->param('imgur_key')) {
		$imgurkey = $cfg->param('imgur_key');
	} else {
		$use_tvdb = "no";
		$log->warn("you need to set imgur_key to use tvdb");
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
        $scene = "no";
}

#indata
my ($path, $release, $is_dir);

sub init1 {
	$path = shift;
	$release = basename($path);
	$log->info("Trying to upload $release");

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
my $mech = WWW::Mechanize->new(autocheck => 0);
my $screens;

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
	if ($mech->uri eq $site_url."/takelogin.php") { 
		$log->error("Login failed!");
		die("Login failed"); 
	}
}

sub create_torrent {
	# No need to create, we have one from rtorrent
	my $torfile = $ARGV[0];
	$torfile =~ s/\/\//\//g;
	return $torfile;
}

sub upload {
        my ($torrent, $nfo, $tdescr, $type) = @_;
		$log->info("Uploading torrent: $torrent");
        #print "Uploading torrent...\n";
		my $descr;
		my $top;
		if ($use_tvdb eq "yes") {
			$top = get_banner();
		}
		if (!$top and $use_tmdb eq "yes") {
			$top = get_poster($tdescr);
		}
		if ($top) {
			$descr = $top."\n";
		}
		if ($screens) {
			$descr .= $tdescr."\n".$screens;
		} else {
			$descr .= $tdescr;
		}
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
        unless ($mech->success) {
			$log->error("Could not upload: unable to reach site");
			die("Could not upload");
		}
        #print $mech->content;
	my $uri = $mech->uri();
	if ($uri =~ /details\.php/) {
		$log->info("Upload successfull: $uri");
		return $uri;
	} else {
		if ($mech->content =~ /<h3>Mislykket\sopplasting!<\/h3>\n<p>(.*)<\/p>/) {
			$log->error("Upload failed: ".$1);
			die("Upload failed: ".$1);
			#print $1."\n";
		}
		if($mech->content =~ /<h3>(.*)<\/h3>/) {
			my $error = $1;
			$log->error("Upload failed: ".$1);
			die("Upload failed: ".$1);
		}
		$log->error("Upload failed");
		die("Upload failed!");
	}
}

sub download_torrent {
        my $uri = shift;
		$log->info("Downloading torrent from $uri");
        #print "Downloading torrent...\n";
        $mech->get($uri);
        $mech->follow_link( url_regex => qr/download/i );
        unless($mech->success) {die("Could not download torrent");}
        open(my $TORFILE, ">", $torrent_auto_dir."/".$release.".torrent") || die("Could not open file: $!");
        #print $TORFILE $mech->content;
		my $tfile = fast_resume($mech->content);
		print $TORFILE $tfile;
        close($TORFILE);
		$log->info($torrent_auto_dir."/".$release.".torrent saved.");
        return $uri;
}

sub fast_resume {
	my $t = bdecode(shift);
	
	$log->info("applying fast-resume");
	
	my $d = $path;
	$d =~ s/$release//;
	#$d .= "/" unless $d =~ m#/$#;
	
	#die "No info key.\n" unless ref $t eq "HASH" and exists $t->{info};
	unless (ref $t eq "HASH" and exists $t->{info}) {
		$log->error("fast-resume: No info key");
		die "No info key.\n";
	}
	
	#my $psize = $t->{info}{"piece length"} or die "No piece length key.\n";
	my $psize;
	if($t->{info}{"piece length"}) {
		$psize = $t->{info}{"piece length"};
	} else {
		$log->error("fast-resume: No piece length key");
		die "No piece length key.\n";
	}

	my @files;
	my $tsize = 0;
	if (exists $t->{info}{files}) {
		#print STDERR "Multi file torrent: $t->{info}{name}\n";
		$log->info("Multi file torrent: $t->{info}{name}");
		for (@{$t->{info}{files}}) {
			push @files, join "/", $t->{info}{name},@{$_->{path}};
			$tsize += $_->{length};
		}
	} else {
		#print STDERR "Single file torrent: $t->{info}{name}\n";
		$log->info("Single file torrent: $t->{info}{name}");
		@files = ($t->{info}{name});
		$tsize = $t->{info}{length};
	}
	my $chunks = int(($tsize + $psize - 1) / $psize);
	$log->info("Fast-resume info: Total size: $tsize bytes; $chunks chunks; ", scalar @files, " files.\n");
	
	#die "Inconsistent piece information!\n" if $chunks*20 != length $t->{info}{pieces};
	if ($chunks*20 != length $t->{info}{pieces}) {
		$log->error("Inconsistent piece information!");
		die "Inconsistent piece information!\n";
	}
	
	$t->{libtorrent_resume}{bitfield} = $chunks;
	for (0..$#files) {
		#die "$d$files[$_] not found.\n" unless -e "$d$files[$_]";
		unless (-e "$d$files[$_]") {
			$log->error("$d$files[$_] not found.");
			die "$d$files[$_] not found.\n";
		}
		my $mtime = (stat "$d$files[$_]")[9];
		$t->{libtorrent_resume}{files}[$_] = { priority => 2, mtime => $mtime };
	};
	$log->info("Fast resume applied");
	
	return bencode $t;
}

my $scount = 0;
sub makescreen {
	my $mediafile = shift;
	unless ($cfg->param('imgur_key')) {
		$log->warn("Make screens impossible without imgur_key");
		return;
	}

	$log->info("Makeing screenshots");
	require Image::Thumbnail;
	require Image::Imgur;
	
	#$cfg->param('password');
	my($ss1, $ss2);
	if ($mediafile =~ /sample/i) {
		$ss1 = 10;
		$ss2 = 20;
	} else {
		$ss1 = 60;
		$ss2 = 160;
	}
	$scount++;
	system('mplayer -ss '.$ss1.' -vo png:z=9 -ao null -frames 2 ' . $mediafile . ' > /dev/null 2>&1');
	my $imgur = new Image::Imgur(key => $imgurkey);
	my $imgurl1 = $imgur->upload("00000002.png");
	my $t1 = new Image::Thumbnail(
		size       => 300,
		create     => 1,
		input      => '00000002.png',
		outputpath => 'thumb.png'
	);
	my $imgurl1thumb = $imgur->upload("thumb.png");
	unlink("00000001.png", "00000002.png", "thumb.png");
	system('mplayer -ss '.$ss2.' -vo png:z=9 -ao null -frames 2 ' . $mediafile . ' > /dev/null 2>&1');
	my $imgurl2 = $imgur->upload("00000002.png");
	my $t2 = new Image::Thumbnail(
		size       => 300,
		create     => 1,
		input      => '00000002.png',
		outputpath => 'thumb.png'
	);
	my $imgurl2thumb = $imgur->upload("thumb.png");
	unlink("00000001.png", "00000002.png", "thumb.png");
	$screens .= '[url='.$imgurl1.'][img]'.$imgurl1thumb.'[/img][/url][url='.$imgurl2.'][img]'.$imgurl2thumb.'[/img][/url]'."\n";
}

sub strip_nfo {
	# If rar-file = scene
	#$log->info("Searching for rar-files");
	if ($_ =~ m/.*\.rar$/) {
		$log->info("rar file found, assuming this is scene");
		$scene = "yes";
	}

		if ($_ =~ m/.*\.(avi|mkv|mp4)$/ and $cfg->param('make_screens') eq "yes") {
			makescreen($File::Find::name);
		}
        if ($_ =~ m/.*\.nfo$/) {
				$log->info("nfo found, stripping..");
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

                $rnfo .= $result;
			$rnfo =~ s/nedlasting\.net//ig; # nedlasting sux
        }
}

sub get_banner {
	if($release =~ /^(.*).S\d{1,}E?\d{0,}/) {
		my $show = $1;
		$show =~ s/\./ /g;
		$log->info("Trying to fetch banner from TVDB");
		$mech->get('http://www.thetvdb.com/api/GetSeries.php?seriesname='.rawurlencode($show).'&language=no');
		if($mech->success) {
			require XML::Simple;
			my $xml = new XML::Simple;
			my $data = $xml->XMLin($mech->content, ForceArray => 1);
			if($data->{'Series'}[0]->{'banner'}[0]) {
				my $tvdburl = 'http://thetvdb.com/banners/'.$data->{'Series'}[0]->{'banner'}[0];
				$log->info("Banner found: ".$data->{'Series'}[0]->{'banner'}[0]);
				require Image::Imgur;
				my $imgur = new Image::Imgur(key => $imgurkey);
				my $imgururl = $imgur->upload($tvdburl);
				#$rnfo = '[img]'.$imgururl.'[/img]'."\n";
				$log->info("Uploaded banner to imgur: ".$imgururl);
				return '[img]'.$imgururl.'[/img]';
			} else {
				$log->warn("Banner not found.");
			}	
		} else {
			$log->warn("Unable to access TVDB");
		}
	}
	return;
}

sub get_poster {
	my $info = shift;
	if($info =~ /(tt\d{7})/) {
		$mech->get('http://api.themoviedb.org/2.1/Movie.getImages/en/json/'.$apikey.'/'.$1);
		$log->info("imdb link found, trying to get poster");
		if ($mech->success) {
			require JSON;
			my $json = JSON->new->utf8(0)->decode($mech->content);
			unless($json->[0] eq "Nothing found.") {
				$log->info("Poster found: ".$json->[0]->{'posters'}[0]->{'image'}->{'url'});
				return '[imgw]'.$json->[0]->{'posters'}[0]->{'image'}->{'url'}.'[/imgw]';
			} else {
				$log->warn("Poster not found.");
			}
		} else {
			$log->warn("Unable to access TMDB");
		}
	}
	return;
}

sub rawurlencode {
	my $unencoded_url = shift;
	my $url = URI::URL->new($unencoded_url);
	return $url->as_string;
}

sub find_type {
        #my $release = shift;
        if ($type) { return $type }
		
		if ($release =~ m/S\d{1,}/i or $release =~ m/(PDTV|HDTV)/i) { #IS TV
			if ($release =~ m/XviD/i) { return "1" }
			if ($release =~ m/x264/i) { return "29" }
			if ($release =~ m/(PAL|NTSC)\.DVDR/i) {return "27" }
		} else { #IS MOVIE
			if ($release =~ m/x264/i) { return "28" }
			if ($release =~ m/XviD/i) { return "25" }
			if ($release =~ m/MP4/i) { return "26" }
			if ($release =~ m/MPEG/i) { return "24" }
			if ($release =~ m/(BluRay|Blu-Ray)/i) { return "19" }
			if ($release =~ m/(PAL|NTSC)\.DVDR/i) {return "20" }
		}
		
        #if ($release =~ m/(BluRay|Blu-Ray)/i) { return "19" }
        #if ($release =~ m/(PDTV|HDTV)\.XviD/i) { return "1" }
        #if ($release =~ m/(PDTV|HDTV)\.x264/i) { return "29" }
        #if ($release =~ m/S\d.*(PAL|NTSC)\.DVDR/i) { return "27" }
        #if ($release =~ m/(PAL|NTSC)\.DVDR/i) { return "20" }
        #if ($release =~ m/x264/i) { return "28" }
        #if ($release =~ m/XviD/i) { return "25" }
        #if ($release =~ m/MP4/i) { return "26" }
        #if ($release =~ m/MPEG/i) { return "24" }
		
		# Use if not found.
		return "1";

        die("Unable to detect type, try -t|--type");
}


if($ARGV[2] eq "NBUL") {
	#$log->info("Script is trying to upload: $ARGV[2]");
	init1($ARGV[1]);
	init2();
}

sub init2 {
	if($is_dir) {
	        find (\&strip_nfo, $path);
	} else {
		$log->warn("$path is not a directory");
		$log->info("Trying to get alternative nfo");
		if (-e $cfg->param('nfo_path')."/".$release.".nfo") {
			$log->info("Alternative nfo found");
			$nfo_file = $cfg->param('nfo_path')."/".$release.".nfo";
			open(my $ALTNFO, "<", $cfg->param('nfo_path')."/".$release.".nfo");
			while(<$ALTNFO>) {
				$rnfo .= $_;
			}
			close($ALTNFO);
			if ($path =~ /.*\.(mkv|avi|mp4)$/) {
				makescreen($path);
			}
		} else {
			$log->error("No NFO found");
			return;
		}
	}

	login();

	my $link = "";
	if($nfo_file && $rnfo) {
	        $link = download_torrent(upload(create_torrent(), $nfo_file, toutf8($rnfo), find_type()));
			$log->info("Done! - $link");
	} else {
			if (-e $cfg->param('nfo_path')."/".$release.".nfo") {
				require File::Copy;
				$log->warn("Using alternative nfo");
				move($cfg->param('nfo_path')."/".$release.".nfo", $path."/".$release.".nfo");
				init2();
				return;
			}
			$log->warn("Nfo not found, making one..");
	        #system("echo \"NFO mangler......\" > $path/mangler.nfo");
			if(open(my $NFOF, ">", $path."/mangler.nfo")) {
				print $NFOF "NFO mangler.........";
				close($NFOF);
			} else {
				$log->error("Unable to make misssing nfo");
				die("Unable to make missing nfo");
			}
			init2();
	}
}

sub toutf8 {
#takes: $from_encoding, $text
#returns: $text in utf8
    #my $encoding = shift;
    my $text = shift;
    #if ($encoding =~ /utf\-?8/i) {
    #    return $text;
    #}
    #else {
        return Encode::encode("ISO-8859-15", Encode::decode("UTF-8", $text));
    #}
}
