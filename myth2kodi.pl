#!/usr/bin/perl
# Copyright (c) 2015 Jeff Cody, <jcody@codyprime.org>
#
# This program is free software; you can redistribute it and/or modify it under
# the terms of the GNU General Public License, Version 2.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE.
#
# See LICENSE.txt for the full license.
#
#
# Some dependency notes:
#
#   On Fedora 21, I had to install the following outside of what
#   was installed with a normal "server" install:
#       yum install expect  # for "unbuffer"
#       yum install perl-WWW-Mechanize perl-Text-CSV_XS perl-Config-Simple
#       cpan App:cpanminus  # for cpanm
#       cpanm Tie::Handle::CSV
#
#   Also, handbrake must be installed, with x264 support, and/or ffmpeg
#   with x264 support.  Mediainfo is required for interlace detection, unless
#   you want to use the slower ffmpeg method.

use WWW::Mechanize;
use JSON -support_by_pp;
use Tie::Handle::CSV;
use File::Basename;
use DBI;
use Text::Wrap qw(wrap $columns $huge);
use Term::ANSIColor qw(:constants);
use Getopt::Std;
use Config::Simple;
use Term::ReadKey;
use File::Basename;

use sigtrap qw(handler progress_print USR1);

$Text::Wrap::columns = 72;

# CSV input file format:
#   "show","episode title","episode description","air date","filename" ...
#
# For myth 0.21, I generated my exported csv via:
#   SELECT title,subtitle,description,originalairdate,basename,filesize,cutlist 
#   FROM recorded 
#   WHERE filesize > 0 ORDER BY seriesid,originalairdate 
#   INTO OUTFILE '/tmp/output.txt' FIELDS TERMINATED BY ',' ENCLOSED BY '"' LINES TERMINATED BY '\n';
# 
my %options=();

# for running mythcommflag
$myth_ssh_user = "jcody";
$myth_ssh_key = "-i /home/jcody/.ssh/home"; 

my @myth_data_dirs;

# x264 / handbrake default options
$X264_PROFILE="High Profile";
$X264_INTERLACED_PRESET="slow";
$X264_PROGRESSIVE_PRESET="slow";
$HANDBRAKE_AUDIO_OPTS="-a 1 -E copy";
$HANDBRAKE_OTHER_OPTS="-O";


my $config_dir = $ENV{"XDG_CONFIG_HOME"};

if (!defined($config_dir)) {
    $config_dir = $ENV{"HOME"}. "/.config";
}

my $config_file = $config_dir . "/" . "myth2kodi.ini";


# -c: config file to use, default is ~/.config/myth2kodi.ini
# -d: dry-run, do not modify anything (but still do interlace detection)
# -m: meta-files only; do everything but encode the video, and
#     don't mark it as done.  This will create the comskip file,
#     the .info file, and create directories.
# -e: print info only; akin to dry-run, but doesn't detect interlace
# -t: print title info only, no modifications.
# -b: DEBUG
# -f: use CSV file [file]
# -s: use myth services api
# -a: use address [address] for myth server
# -p: use port on myth server of [port], default 6544
# -i: interactive mode
# -M: Myth version (for commflagging)
# -R: delete recording, but only when combined with -s (remote server)
# -n: only encode show with "name"
# -u: get upcoming list only, implies -t
# -o: only search for files store in directory 'dir'
# -S: use SSH to fetch comskip data (0 localhost, 1 ssh)
# -x: overwrite existing files, and ignore done markers
# -E: choose encoder (ffmpeg, or HandbrakeCLI)
# -w: max width of video
# -X: if combined with -R, delete remote recordings that have already been
#     encoded, without re-encoding
# -k: skip encoding episodes for which there cannot be determined episode or
#     season metadata.
# -K: Do not skip encoding episodes for which there cannot be determined episode or
#     season metadata. (overrides -k or .ini settings)
# -P: prompt for unknown episodes
# -N: Do not prompt for unknown episodes (overrides -P or .ini setting)

my $very_dry_run = 0;
my $dry_run = 0;
my $meta_only = 0;
my $csv_file;
my $only_dir = "";
my $name = "";
my $myth_server;
my $myth_host;
my $myth_port;
my $interactive=0;
my $upcoming=0;
my $delete_rec=0;
my $use_ssh=0;
my $myth_version;
my $overwrite=0;
my $max_width=-1;
my $delete_only;
my $skip_nometa=0;
my $prompt_for_info=0;
my $encoder="HandbrakeCLI";
my $x264_profile            = $X264_PROFILE;
my $x264_interlaced_preset  = $X264_INTERLACED_PRESET;
my $x264_progressive_preset = $X264_PROGRESSIVE_PRESET;
my $handbrake_audio_opts    = $HANDBRAKE_AUDIO_OPTS;
my $handbrake_other_opts    = $HANDBRAKE_OTHER_OPTS;

getopts("bdmieutsS:Rn:f:M:o:c:a:xw:E:XkKPN", \%options);

if (defined($options{m}) && defined($options{d})) {
    die "Mutually exclusive options specified\n";
}
if (defined($options{m}) && defined($options{e})) {
    die "Mutually exclusive options specified\n";
}

if (defined($options{b})) {
    $debug=1;
}

if (defined($options{c})) {
    $config_file = $options{c};
}

my %config = read_config($config_file);

@myth_data_dirs         = @ {$config{"storage.src_dirs"} };
@check_dirs             = @ {$config{"storage.chk_dirs"} };
$base                   = $config{"storage.dst_dir"};
$myth_ssh_user          = $config{"myth-server.ssh_user"};
$myth_ssh_key           = $config{"myth-server.ssh_key"};
$myth_host              = $config{"myth-server.addr"};
$myth_port              = $config{"myth-server.port"};
$myth_version           = $config{"myth-server.ver"};
$use_ssh                = $config{"myth-server.use_ssh"};

$ENCODE                 = $config{"encode.script_path"} . "/" . $config{"encode.script"};
$encoder                = $config{"encode.encoder"};

# x264 options
$x264_profile           = $config{"x264.profile"};
$x264_interlaced_preset = $config{"x264.interlaced_preset"};
$x264_progressive_preset= $config{"x264.progressive_preset"};
$handbrake_audio_opts   = $config{"handbrake.audio_opts"};
$handbrake_other_opts   = $config{"handbrake.other_opts"};

# other
$skip_nometa            = $config{"other.skip_unknown"};
$prompt_for_info        = $config{"other.prompt_unknown_info"};


if (defined($options{S})) {
    if (($options{S} == 0) || ($options{S} == 1)) {
        $use_ssh = $options{S};
    } else {
        die "Invalid parameter for -S: \'$options{S}\'\n";
    }
}


if (defined($options{E})) {
    $encoder = $options{E};
    print "encoder is $encoder\n";
}

if (defined($options{w})) {
    $max_width = $options{w};
}

if (defined($options{f})) {
    $csv_file = $options{f};
}

if (defined($options{o})) {
    $only_dir = $options{o};
}

if (defined($options{n})) {
    $name = $options{n};
} 

if (defined($options{s})) {
    $myth_server = 1;
}

if (defined($options{a})) {
    $myth_host = $options{a};
}

if (defined($options{p})) {
    $myth_port = $options{p};
}

if (defined($options{i})) {
    $interactive=1;
}

if (defined($options{x})) {
    $overwrite=1;
}

if (defined($options{u})) {
    $upcoming="upcoming";
    $title_only = 1;
    $very_dry_run = 1;
}

if (defined($options{R})) {
    $delete_rec=1 if ($myth_server) || die "-R can only be used with -s\n";
}

if (defined($options{X})) {
    $delete_only=1 if ($delete_rec) || die "-X can only be used in conjunction with -R\n";
}

if (defined($options{M})) {
    $myth_version = $options{M};
}


if (defined($options{t})) {
    $title_only = 1;
    $very_dry_run = 1;
    $dry_run = 1;
} elsif (defined($options{e})) {
    $very_dry_run = 1;
    $dry_run = 1;
} elsif (defined($options{d})) {
    $dry_run = 1;
}

if (defined($options{m})) {
    $meta_only = 1;
}

if (defined($options{k})) {
    $skip_nometa=1;
}

if (defined($options{K})) {
    $skip_nometa=0;
}

if (defined($options{P})) {
    $prompt_for_info=1;
}

if (defined($options{N})) {
    $prompt_for_info=0;
}


##------------------------------------
# END option parsing
#

my %shows;
my %gi;
my %i;
my $total_shows=0;
my $scan_cnt=0;
my $missing_cnt=0;
my $curr_index=1;


#------------------------------------------------------------------------------
# Read in show data
#
# We read shows in either by CSV file, or by the Myth Services API
if ($csv_file) {
    ($shows_ref, $gi_ref) = parse_csv_file($csv_file, $name);
} elsif ($myth_server) {
    ($shows_ref, $gi_ref) = fetch_myth_recordings_list($myth_host, $myth_port, $name, $upcoming);
}

%shows = %{ $shows_ref };
%gi = %{ $gi_ref };


my $to_encode=0;
#------------------------------------------------------------------------------
# For all the shows we are going to import, verify that we can locate each one
# in the directories specified in the config file src_dirs.
#
# Shows not found will be ignored.
print "\n";
my $sub_idx;
# scan ahead of time for see if we can find each file in our
# hash list
foreach $show (keys %shows) {
    for (my $idx = 0; $idx < $gi{$show}; $idx++) {

        # If we are just listing upcoming shows, then
        # 'mark' them all as present.  The files for shows
        # not yet recorded do not exist, but if we pretend they
        # do we can run a 'dry-run' still.
        if ($upcoming eq "upcoming") {
            $scan_cnt++;
            $sub_idx{$show}[$i{$show}] = $idx;
            $total_shows++;
            $shows{$show}{valid}[$idx] = 1;
            $shows{$show}{encode}[$idx] = 1;
            $to_encode++;
            $i{$show}++;
            next;
        }

        $scan_cnt++;
        my $found = 0;
        my $idx_str = sprintf("[%5d]", $total_shows);
        print "\e[K";
        print YELLOW, $idx_str, RESET, " searching for $shows{$show}{basename}[$idx]...";

        foreach my $dir (@myth_data_dirs) {
            if (($only_dir ne "") && ($only_dir ne "$dir")) {
                next;
            }

            my $showpath = `find "$dir" -name "$shows{$show}{basename}[$idx]"`;
            if (defined($showpath) && $showpath ne '') {
                chomp($showpath);
                $shows{$show}{fullname}[$idx] = $showpath;
                $found = 1;
                last;
            }
        }

        if (!$found) {
            $missing_cnt++;
            print BOLD, RED, "not found! ($show, $shows{$show}{title}[$idx])\n", RESET;
            $shows{$show}{valid}[$idx] = 0;
        } else {
            print GREEN, "found!\r", RESET;
            $shows{$show}{valid}[$idx] = 1;
            $sub_idx{$show}[$i{$show}] = $idx;
            $i{$show}++;
            if (!$interactive) {
                queue_show($show, $idx);
            }
        }
    }
}

print "\e[K";
print "Scanned $scan_cnt files, found $total_shows, missing $missing_cnt\n";


#------------------------------------------------------------------------------
# If we are in interactive mode, prompt
# the user for what shows / episodes to encode
if ($interactive) {
    my $show;
    my $prompt_txt;
    print "Interactive mode\n";
    foreach $show (keys %shows) {
        my @opts = ('y','A','n','N');
        my $r = prompt("Import episodes from", $show, \@opts , 'n');
        print "\n";

        if ($$r eq 'N') {
            last;
        }
        for (my $idx = 0; $idx < $gi{$show} && $$r ne "n"; $idx++) {
            my $resp;
            $prompt_txt = sprintf("\t%s %-25.25s %-1s",($shows{$show}{airdate}[$idx]), $shows{$show}{title}[$idx], "");
            if ($$r eq "y") {
                @opts = ('y', 'n', 'p');
                my $action = 0;
                while ($action == 0) {
                    $resp = prompt("$prompt_txt", "", \@opts, 'y');
                    if ($$resp eq "p") {
                        # do preview
                        print "\nPreviewing $shows{$show}{title}[$idx]\n";
                        `vlc "$shows{$show}{fullname}[$idx]" 2>&1 >/dev/null`;
                    } else {
                        $action = 1;
                    }
                }
            }
            if (($$r eq "A") || (lc($$resp) eq lc("Y"))) {
#                print "$show - $idx\n";
                print CYAN, "\r+$prompt_txt", RESET;
                queue_show($show, $idx);
           }
           print "\n";
        }
    }
}

#------------------------------------------------------------------------------
# Now loop through for each show we are going to encode,
# or print information about.

my $show_season;
my $show_number;
foreach $show (keys %shows) {
    $num_entries = $i{$show};

    if ($num_entries > 0) {
        print "\n\n";
        print BOLD, "──────────────┤ $show: ", RESET, " $num_entries episodes ",BOLD, "\n", RESET;
        # Looking up the information will gives us the information we need to
        # name the file properly, for xbmc/kodi to properly parse and fetch metadata.
        my $showname = lc($show);
        $showname =~ s/ /+/g;
        my $url = "http://imdbapi.poromenos.org/js/?name=" . $showname;
        if ($year) {
            $url .= "&year=$year";
        }
        ($show_season, $show_number) = fetch_imdb_info($url, $show);
    }


    # Now iterate though each episode for our current $show.
    my $shows_parsed = 0;
    for ($k = 0; $k < $num_entries; $k++) {

        $j = $sub_idx{$show}[$k];

        if (($shows{$show}{valid}[$j] != 1) || ($shows{$show}{encode}[$j] != 1) ) {
            next;
        }

        my $newname;
        my $comskip_name;
        my $status_name;
        my $info_name;
        my $match=0;
        my $episode  = $shows{$show}{title}[$j];
        my $filename = $shows{$show}{fullname}[$j];
        my $basename = $shows{$show}{basename}[$j];
        my $summary  = $shows{$show}{summary}[$j];
        my $airdate  = $shows{$show}{airdate}[$j];
        my $airdate_ = $airdate;
        my $myth_season = $shows{$show}{season}[$j];
        my $myth_number = $shows{$show}{episode}[$j];

        my @exts = qw(.m4v .mpg .ts .mp4 .mkv .mpeg2 .mpeg1);
        my($base_filename, $base_dirs, $base_suffix) = fileparse($basename, @exts);

        $airdate_ =~ s/-//g;
        my $nametmpl;
        my $tvdb_suffix="";
        my $episode_sanitized  = $episode;
        $episode_sanitized =~ s/ /_/g;
        $episode_sanitized =~ s/[^A-Za-z0-9\-\._]//g;
        my $match_warning;
        my $no_meta_found = 0;
        my $show_suffix;
        my $done_exists = 0;

        if (${$show_season}{$episode}) {
            $show_suffix = "$show/Season ${$show_season}{$episode}";
            $tvdb_suffix = sprintf(".S%02dE%02d", ${$show_season}{$episode}, ${$show_number}{$episode});
        } else {
            # This isn't fatal, we just weren't able to find any metadata on this episode.
            # Place in showname/UNKNOWN directory, with filename  'showname-airdate-episodename'
            $match_warning = "warning: no episode found on imdb for \"$episode\"\n";
            if ($myth_season && $myth_number) {
                $show_suffix = "$show/Season $myth_season";
                $tvdb_suffix = sprintf(".S%02dE%02d", $myth_season, $myth_number);
            } else {
                my $season_no = "";
                my $episode_no = "";

                if ($prompt_for_info) {
                    print GREEN, "Enter episode info for: $airdate - $show - $episode\n", RESET;
                    $season_no = prompt_text(GREEN . "Enter Season Number", "", "");
                    $episode_no = prompt_text(GREEN . "Enter Episode Number", "", "");
                }
                if ($$season_no ne "" && $$episode_no ne "") {
                    $show_suffix = "$show/Season $$season_no";
                    $tvdb_suffix = sprintf(".S%02dE%02d", $$season_no, $$episode_no);
                } else {
                    $no_meta_found = 1;
                    $show_suffix = "$show/UNKNOWN";
                }
            }
        }

        $dirname = "$base/$show_suffix";
        $nametmpl      = sprintf("$dirname/$show-$airdate_-$episode_sanitized" . "$tvdb_suffix",
                                 ${$show_season}{$episode}, ${$show_number}{$episode});
        $status_suffix = sprintf(".$show-$airdate_-$episode_sanitized" . "$tvdb_suffix.done",
                                 ${$show_season}{$episode}, ${$show_number}{$episode});

        foreach my $dir (@check_dirs) {
            if (-e "$dir/$show_suffix/$status_suffix") {
                $done_exists = 1;
            }
        }

        $status_name = "$dirname/$status_suffix";

        if ($encoder eq "copy") {
            $newname =      $nametmpl . "$base_suffix";
        } else {
            $newname =      $nametmpl . ".m4v";
        }
        $comskip_name = $nametmpl . ".txt";
        $info_name =    $nametmpl . ".info";
        $error_log =    $nametmpl . ".log";

        $shows_parsed++;

        # Just to make printing it nicer, we don't need this for file naming anymore
        $tvdb_suffix =~ s/\.//;

        my $l = length("$total_shows");
        my $indices_str = sprintf("[%0$l"."d/%0$l"."d, %0$l"."d,%0$l"."d]", $curr_index,
                                                                            $total_shows,
                                                                            $shows_parsed,
                                                                            $num_entries);


        my %recinfo;
        $recinfo{basename}  = $basename;
        $recinfo{chanid}    = $shows{$show}{chanid}[$j];
        $recinfo{starttime} = $shows{$show}{start}[$j];
        $recinfo{use_ssh}   = $use_ssh;


        if ($skip_nometa && $no_meta_found) {
                print CYAN, "$indices_str", RESET,
                    RED, "\tNo metadata found, skipping \"$show $tvdb_suffix\", \'$episode\'\n", RESET;
        } else {

        `mkdir -p "$dirname"` if (!$very_dry_run && !$dry_run);

        if ((-e "$status_name" || $done_exists) && !$overwrite) {
            if (($delete_only == 1) && ($delete_rec == 1)) {
                if ($episode_sanitized eq "") {
                    print RED, "Refusing to delete recording with empty episode name, out of caution\n", RESET;
                } else {
                    delete_remote_myth_recording($myth_host,
                                                 $myth_port,
                                                 $recinfo{chanid},
                                                 $recinfo{starttime}) if (!$dry_run && !$meta_only);
                    print CYAN, "$indices_str", RESET,
                        BOLD, MAGENTA, "\tDone marker exists, deleting from myth @ $myth_host: \"$show $tvdb_suffix\", \'$episode\'\n", RESET;
                }
            } else {
                print CYAN, "$indices_str", RESET,
                    BOLD, YELLOW, "\tDone marker exists, skipping \"$show $tvdb_suffix\", \'$episode\'\n", RESET;
            }
        } elsif (!$delete_only) {
            my $action = "Encoding";

            if (-e "$newname") {
                my $newname_bak = "$newname" . ".bak";
                my $num = 1;
                while (-e "$newname_bak") {
                    $newname_bak = "$newname" . ".bak" . "$num";
                    $num++;
                }
                print RED, "moving original to $newname_bak\n" if (!$title_only);
                `mv "$newname" "$newname_bak"`;
            }

            if ($meta_only) {
                $action  = "Write metadata";
            }
            print RED, "$match_warning" if (!$title_only);
            print CYAN, "$indices_str\t", BOLD, "$action: \"$show $tvdb_suffix\", \'$episode\'\n", RESET;
            print  "╔═ $filename\n" if (!$title_only && !$meta_only);
            print  "╚═ $newname\n" if (!$title_only && !$meta_only);


            my $x264_preset;
            my $interlaced;

            # We detect interlaced, because we may decide to encode differently in interlaced
            # mode.  Specifically, we made decide to frame-double and use a more expensive
            # deinterlacer.  We just pass this info along, and let the encode script decided
            # what to do with it.
            $interlaced = detect_interlaced($filename) if (!$very_dry_run && !$meta_only);
            if (${$interlaced} eq "interlaced") {
                $x264_preset = $x264_interlaced_preset;
            } else {
                ${$interlaced} = "progressive";  # if not explicitely set to interlaced, set to progressive
                $x264_preset = $x264_progressive_preset;
            }

            if (-e "$comskip_name" && !$overwrite) {
                print BOLD, YELLOW, "Comskip file exists, not overwriting\n", RESET if (!$very_dry_run);
            } else {
                my $comskip = fetch_comskip(%recinfo) if (!$title_only);
                if (!$dry_run && !$very_dry_run) {
                    if (-e "$comskip_name") {
                        my $comskip_bak = "$comskip_name" . ".bak";
                        my $num = 1;
                        while (-e "$comskip_bak") {
                            $comskip_bak = "$comskip_name" . ".bak" . "$num";
                            $num++;
                        }
                        `mv "$comskip_name" "$comskip_bak"`;
                    }

                    print "opening $comskip_name\n";
                    open(my $fh, '>', "$comskip_name") or die "Could not open file '$comskip_name' $!";
                    print $fh "${$comskip}";
                    close $fh;
                }
            }

            if (-e "$info_name" && !$overwrite) {
                print BOLD, YELLOW, "Info file exists, not overwriting\n", RESET if (!$very_dry_run);
            } else {
                if (!$dry_run && !$very_dry_run) {
                    if (-e "$info_name") {
                        my $info_name_bak = "$info_name" . ".bak";
                        my $num = 1;
                        while (-e "$info_name_bak") {
                            $info_name_bak = "$info_name" . ".bak" . "$num";
                            $num++;
                        }
                        `mv "$info_name" "$info_name_bak"`;
                    }

                    # This could really be optional, it isn't used by xbmc/kodi.  But it might be nice
                    # to have some simple metadata in a human-readable format, when manually browsing via
                    # a shell.
                    open(my $fh, '>', "$info_name") or die "Could not open file '$info_name' $!";
                    print $fh "$show\n";
                    printf $fh "S%02dE%02d: $episode\n", ${$show_season}{$episode}, ${$show_number}{$episode};
                    print $fh "$airdate\n";
                    print $fh "------------------------------------------------\n";
                    print $fh wrap('', '', $summary);
                    print $fh "\n\n";
                    close $fh;
                }
            }


            #-----------------
            # Time to encode!
            #
            my $start_time = time();
            print BRIGHT_WHITE, ON_BLACK;

            my $run_dry = "-1";
            $run_dry = "dry-run" if ($dry_run || $meta_only);

            if ($encoder eq "copy") {
                $ret = system("unbuffer nice -n 18 cp -v \"$filename\" \"$newname\"") if (!$title_only && !$meta_only);
            } else {
                $ret = system("unbuffer nice -n 18 \"$ENCODE\" \"$filename\" \"$newname\" \\
                              ${$interlaced} $x264_preset \"$error_log\" $run_dry $max_width $encoder") if (!$title_only && !$meta_only);
            }
            print "  ", RESET;

            if ($ret != 0) {
                print BOLD, RED, "Failure! (marked undone) " if (!$title_only);
            } else {
                `touch "$status_name"` if (!$dry_run && !$very_dry_run && !$meta_only);
                print "\e[K\r";
                print BOLD, GREEN, "Success! " if (!$title_only && !$meta_only);
                `rm -f "$error_log"` if (!$dry_run && !$meta_only);

                delete_remote_myth_recording($myth_host,
                                             $myth_port,
                                             $recinfo{chanid},
                                             $recinfo{starttime}) if ($delete_rec && !$dry_run && !$meta_only);
            }

            #---- end encoding

            # Just some simple metrics for the time it took for this encode.
            my $end_time   = time();
            my $encode_sec = $end_time - $start_time;
            my $hours      = int($encode_sec / 3600);
            my $min        = int(($encode_sec % 3600) / 60);
            my $sec        = $encode_sec % 60;
            my $timestring = sprintf("%02d:%02d:%02d", $hours, $min, $sec);

            print "Encoded in $timestring (hh:mm:ss)\n", RESET if (!$title_only && !$meta_only);
    

        }

        }

        $curr_index++;
    }
}

#------------------------------------------------------------------------------
# Determine if the video file to encode is interlaced or not.
#
sub detect_interlaced
{
    my ($filename) = @_;
    my $interlaced = "progressive";

    print "Interlace detection... ";

    $interlaced = lc(`mediainfo --Inform="Video;%ScanType%" "$filename"`);
    chomp $interlaced;
    print BOLD, "$interlaced video\n", RESET;
    return (\$interlaced);
}


#------------------------------------------------------------------------------
# Determine if the video file to encode is interlaced or not.
#
# This is most definitely NOT perfect. Err more on the side of progressive, so
# require > 50% of detected frames to be detected as Top Field First + Bottom
# Field First frames.
#
# This currently relies on ffmpeg.  Maybe we should do like encode, and just
# pass this off to a separate script.
#
# Update: deprecate the ffmpeg method, perhaps fall back to this if
#         mediainfo is not installed.
sub detect_interlaced_ffmpeg
{
    my ($filename) = @_;
    my $frame_cnt = 2000;
    my $interlaced = "progressive";

    print "Interlace detection... ";

    my $idet = `ffmpeg -filter:v idet -frames:v $frame_cnt -an -f rawvideo -y /dev/null -i "$filename" 2>&1|grep TFF`;
    foreach my $line (split /[\n]+/, $idet) {
        @output = split(':', $line);
        my @tff = split(' ', $output[2]);
        my @bff = split(' ', $output[3]);
        $score += $tff[0] + $bff[0];
    }

    # Somewhat arbitrary - we are looking for a preponderance of TFF and BFF frames.
    # This score cutoff we determine empiracly from a sample of ~700 files recorded OTA.
    if ($score > $frame_cnt / 1.1) {
        $interlaced = "interlaced";
        print BOLD, "interlaced video\n", RESET;
    } else {
        print BOLD, "progressive video\n", RESET;
    }

    return (\$interlaced);
}


#------------------------------------------------------------------------------
# Get the commercial skip list from Myth, and translate it to comskip format.
#
# This is a bit hacky (of course, you are reading a Perl program, so you
# expected it).
#
# There is no Myth Services API to get the commercial skip list, surprisingly
# enough.
#
# We are left with either parsing the data directly from SQL tables (which may
# change from version to version), or using some commandline myth tools.
sub fetch_comskip
{
    my $comskip;
    my (%recinfo) = @_;

    my $basename = $recinfo{basename};
    my $chanid   = $recinfo{chanid};
    my $starttime = $recinfo{starttime};

    my $raw;
    my $cmd;

    # I am not sure 0.21 is the correct cut-off. All I know is I have a 0.21 install,
    # and a 0.27 install - check, and adjust as needed.
    if ($myth_version <= 0.21) {
        $cmd = "mythcommflag --getskiplist -f $basename | grep Skip";
    } else {
        # mythcommflag will just generate the commercial skip data 
        $cmd = "mythutil --getskiplist --chanid $chanid --starttime $starttime| grep Skip";
    }

    if ($recinfo{use_ssh} == 1) {
        $raw = `ssh $myth_ssh_key $myth_ssh_user\@$myth_host "$cmd" 2>/dev/null`;
    } else {
        $raw = `$cmd`;
    }

    my @skiplist = split(':', $raw);

    $skiplist[1] =~ s/\-/\t/g;
    $skiplist[1] =~ s/,/\n/g;

    $skip = "FILE PROCESSING COMPLETE\n------------------------\n" . $skiplist[1];

    return (\$skip);
}


#------------------------------------------------------------------------------
# Grab and parse data from IMDB API.
#
# See: http://imdbapi.poromenos.org/
sub fetch_imdb_info
{
  my %imdb_season = ();
  my %imdb_number = ();
  my %imdb_year = ();
  my ($imdbapi_url, $series) = @_;
  my @years;
  my $season;
  my $number;
  my $imdb_showname;


  my $json_text = fetch_json($imdbapi_url);

  foreach my $key (keys %{$json_text}) {
      $imdb_showname = $key;
  }

  if (@{$json_text->{shows}}) {
      foreach my $showname(@{$json_text->{shows}} ) {
          push (@years, $showname->{year});
      }
  }

  if (@years) {
      foreach my $year (@years) {
          my $imdbapi_url_y = $imdbapi_url . "&year=$year";
          ($season, $number) = fetch_imdb_info($imdbapi_url_y, $series);
          foreach $tmp_key (keys %{$season}) {
              if (not defined $imdb_season{$tmp_key}) {
                  $imdb_season{$tmp_key} = ${$season}{$tmp_key};
                  $imdb_number{$tmp_key} = ${$number}{$tmp_key};
                  $imdb_year{$tmp_key}   = $year;
              }
          }
      }
  } else {
      if (lc $imdb_showname eq lc $series) {
          $series = $imdb_showname;
      }

      foreach my $episode( @{$json_text->{$series}->{episodes}} ) {
          $imdb_season{$episode->{name}} = $episode->{season};
          $imdb_number{$episode->{name}} = $episode->{number};
      }
  }

  return (\%imdb_season, \%imdb_number, \%imdb_year);
}


#------------------------------------------------------------------------------
# Fetch recordings list from Myth Services API
#
# We can fetch either current recordings, or upcoming
# recordings.
sub fetch_myth_recordings_list
{
  my ($mythip, $mythport, $name, $upcoming) = @_;
  my $myth_url;
  my %i;
  my %shows;

  if ($upcoming ne "upcoming") {
      $myth_url = "http://" . $mythip . ":" . $mythport . "/Dvr/GetRecordedList";
  } else {
      $myth_url = "http://" . $mythip . ":" . $mythport . "/Dvr/GetUpcomingList";
  }

  print "$myth_url\n";
  my $json_text = fetch_json($myth_url);

  my $show;
  my $title;
  foreach my $program( @{$json_text->{ProgramList}->{Programs}} ) {
      if (($name eq "") || (lc($name) eq lc($program->{Title}))) {
          $show  = $program->{Title};       # what myth labels "Title", I call show name
          $title = $program->{SubTitle};    # what myth labels "Subtitle", I call the episode title

          $shows{$show}{title}   [$i{$show}] = $title;
          $shows{$show}{summary} [$i{$show}] = $program->{Description};
          $shows{$show}{airdate} [$i{$show}] = $program->{Airdate};
          $shows{$show}{basename}[$i{$show}] = $program->{FileName};
          $shows{$show}{season}  [$i{$show}] = $program->{Season};
          $shows{$show}{episode} [$i{$show}] = $program->{Episode};
          $shows{$show}{start}   [$i{$show}] = $program->{Recording}->{StartTs};
          $shows{$show}{chanid}  [$i{$show}] = $program->{Channel}->{ChanId};
          $i{$show}++;
      }
  }
  return (\%shows, \%i);
}


#------------------------------------------------------------------------------
# Parse a CSV file, containing shows and metadata
# and encode those files.
sub parse_csv_file
{
    my ($csv_file, $name) = @_;
    my %gi;
    my %shows;

    if ($csv_file) {
        my $csv_fh = Tie::Handle::CSV->new($csv_file, header => 0);
        while (my $csv_line = <$csv_fh>)
        {
            if (($name eq "") || (lc($name) eq lc($csv_line->[0]))) {
                $show = $csv_line->[0];
                $shows{$show}{title}[$gi{$show}]    = $csv_line->[1];
                $shows{$show}{summary}[$gi{$show}]  = $csv_line->[2];
                $shows{$show}{airdate}[$gi{$show}]  = $csv_line->[3];
                $shows{$show}{basename}[$gi{$show}] = $csv_line->[4];
                undef $shows{$show}{season}[$gi{$show}];    # currently not supported in CSV
                undef $shows{$show}{episode}[$gi{$show}];   # currently not supported in CSV
                $gi{$show}++;
            }
        }
    }
    return (\%shows, \%gi);
}


#------------------------------------------------------------------------------
# Delete a remote myth recording via the
# services api.
#
# We needed passed:
#   $mythip: address of the remote myth server
#   $mythport: port on the remote server
#   $chanid: ChanId of the recording
#   $starttime: StartTs of the recording.
#
sub delete_remote_myth_recording
{
  my ($mythip, $mythport, $chanid, $starttime) = @_;
  
  my $myth_url = "http://" . $mythip . ":" . $mythport . "/Dvr/RemoveRecorded?ChanId=$chanid&StartTime=$starttime";
  my $www = WWW::Mechanize->new();

  print BOLD, "Deleting recording\n", RESET;

  # The myth services API states that this requires a POST, since
  # it modifies data.  However, on 0.27 at least, a POST fails.  But a
  # standard HTTP GET method works fine.
  #$www->post($myth_url, [ChanId => "$chainid", StartTime => "$starttime"]);
  $www->get( $myth_url );
}


#------------------------------------------------------------------------------
# generic function to grab json text from a URL.  We don't parse the text,
# but return it in %json_text.
sub fetch_json
{
  my ($json_url) = @_;
  my $www = WWW::Mechanize->new();

  # mainly for myth services api
  $www->add_header(Accept => 'application/json');

  my $json_text;
  
  eval{
      $www->get( $json_url );
      my $json_data = $www->content();

      # relax, man
      my $json = JSON->new->allow_nonref
                          ->utf8
                          ->relaxed
                          ->escape_slash
                          ->loose
                          ->allow_singlequote
                          ->allow_barekey();

      $json_text = $json->decode($json_data);
  };

  if($@){
      die BOLD, RED, "Fatal: json parser crash $@\n", RESET;
  }

  return (\%{$json_text});
}


#------------------------------------------------------------------------------
# Read in the configuration file
sub read_config {
    my ( $cfg_file ) = @_;
    my %config;
    my %default;
    my %settings;

    print "read_config reading $cfg_file\n";

    Config::Simple->import_from("$cfg_file", \%config) || die Config::Simple->error();

    if ($config{"storage.src_dirs"} eq "") {
        die "You must define the source directories (see [storage] in $cfg_file)\n";
    }
    if ($config{"storage.dst_dir"} eq "") {
        die "You must define the destination directory (see [storage] in $cfg_file)\n";
    }
    if ($config{"myth-server.addr"} eq "") {
        die "You must the myth backend ip address (see [myth-server] in $cfg_file)\n";
    }

    return %config;
}


#------------------------------------------------------------------------------
# Simple helper function.
#
# Prints supplied $txt and $btxt to stdout (we will print $btxt in bold).
#
# @opts are the options we accept - e.g., 'y', 'n', etc.  They are
# case-sensitive.
#
# $default is the default option if the user just pressed 'enter'.
#
# We will loop forever, reprinting the question, until we get a valid response.
sub prompt
{
    my ($txt, $btxt, $opts, $default) = @_;
    my $r;
    my %o;

    for (@{ $opts }) { $o{$_} = 1; };

    my $opt_txt = join('/', @{ $opts });

    ReadMode('cbreak');
    print "$txt ", BOLD, "$btxt", RESET, " [$opt_txt] ($default)? ";
    while ($o{$r} != 1) {
        while (not defined ($r = ReadKey(-1))) {
        }
#        $| = 1; $r = <STDIN>; chomp $r;
        if ($r eq "") {
            $r = $default;
        }
    }
    print "$r";
    ReadMode('restore');
    return (\$r);
}

#------------------------------------------------------------------------------
# Simple helper function.
#
# Prints supplied $txt and $btxt to stdout (we will print $btxt in bold).
#
# @opts are the options we accept - e.g., 'y', 'n', etc.  They are
# case-sensitive.
#
# $default is the default option if the user just pressed 'enter'.
#
# We will loop forever, reprinting the question, until we get a valid response.
sub prompt_text
{
    my ($txt, $btxt, $default) = @_;
    my $r;

    print "$txt ", BOLD, "$btxt", RESET, ":  ";
    while (not defined ($r = ReadLine(0))) { }
    chomp $r;
    if ($r eq "") {
        $r = $default;
    }
    return (\$r);
}

#------------------------------------------------------------------------------
# Queue a show for transcoding
sub queue_show
{
    my ($show, $idx) = @_;

    $shows{$show}{encode}[$idx] = 1;
    $to_encode++;
    $total_shows++;
}


#------------------------------------------------------------------------------
# Since we output status, don't know why we'd need this.  But I did in the
# early stages of the script, so I'll leave it here in case you are redirecting
# STDOUT to a file.  SIGUSR1 will cause us to print the current progress to
# STDERR.
sub progress_print
{
    print STDERR "\n### Progress: $curr_index/$total_shows\n";
}


