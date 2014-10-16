require 'base64'
require 'fileutils'
require 'uri'
require 'optparse'

options = {
  user_home: ENV['HOME'],
  private_key_file_path: nil,
  formatted_output_file_path: nil
}

opt_parser = OptionParser.new do |opt|
  opt.banner = "Usage: git_clone.rb [OPTIONS]"
  opt.separator  ""
  opt.separator  "Options (options without [] are required)"

  opt.on("--repo-url URL", "repository url") do |value|
    options[:repo_url] = value
  end

  opt.on("--branch [BRANCH]", "branch name. IMPORTANT: if tag is specified the branch parameter will be ignored!") do |value|
    options[:branch] = value
  end

  opt.on("--tag [TAG]", "tag name. IMPORTANT: if tag is specified the branch parameter will be ignored!") do |value|
    options[:tag] = value
  end

  opt.on("--commit-hash [COMMITHASH]", "commit hash. IMPORTANT: if commit-hash is specified the branch and tag parameters will be ignored!") do |value|
    options[:commit_hash] = value
  end

  opt.on("--dest-dir [DESTINATIONDIR]", "local clone destination directory path") do |value|
    options[:clone_destination_dir] = value
  end

  opt.on("--auth-username [USERNAME]", "username for authentication - requires --auth-password to be specified") do |value|
    options[:auth_username] = value
  end

  opt.on("--auth-password [PASSWORD]", "password for authentication - requires --auth-username to be specified") do |value|
    options[:auth_password] = value
  end

  opt.on("--auth-ssh-raw [SSH-RAW]", "Raw ssh private key to be used") do |value|
    options[:auth_ssh_key_raw] = value
  end

  opt.on("--auth-ssh-base64 [SSH-BASE64]", "Base64 representation of the ssh private key to be used") do |value|
    options[:auth_ssh_key_base64] = value
  end

  opt.on("--formatted-output-file [FILE-PATH]", "If given a formatted (markdown) output will be generated") do |value|
    options[:formatted_output_file_path] = value
  end

  opt.on("-h","--help","Shows this help message") do
    puts opt_parser
  end
end

opt_parser.parse!

if options[:formatted_output_file_path] and options[:formatted_output_file_path].length < 1
  options[:formatted_output_file_path] = nil
end

puts "Provided options: #{options}"

unless options[:repo_url] and options[:repo_url].length > 0
  puts opt_parser
  exit 1
end



# -----------------------
# --- functions
# -----------------------


def write_private_key_to_file(user_home, auth_ssh_private_key)
  private_key_file_path = File.join(user_home, '.ssh/bitrise')

  # create the folder if not yet created
  FileUtils::mkdir_p(File.dirname(private_key_file_path))

  # private key - save to file
  File.open(private_key_file_path, 'wt') { |f| f.write(auth_ssh_private_key) }
  system "chmod 600 #{private_key_file_path}"

  return private_key_file_path
end


# -----------------------
# --- main
# -----------------------

# normalize input pathes
options[:clone_destination_dir] = File.expand_path(options[:clone_destination_dir])
if options[:formatted_output_file_path]
  options[:formatted_output_file_path] = File.expand_path(options[:formatted_output_file_path])
end


#
prepared_repository_url = options[:repo_url]

used_auth_type=nil
if options[:auth_ssh_key_raw] and options[:auth_ssh_key_raw].length > 0
  used_auth_type='ssh'
  options[:private_key_file_path] = write_private_key_to_file(options[:user_home], options[:auth_ssh_key_raw])
elsif options[:auth_ssh_key_base64] and options[:auth_ssh_key_base64].length > 0
  used_auth_type='ssh'
  private_key_decoded = Base64.strict_decode64(options[:auth_ssh_key_base64])
  options[:private_key_file_path] = write_private_key_to_file(options[:user_home], private_key_decoded)
elsif options[:auth_username] and options[:auth_username].length > 0 and options[:auth_password] and options[:auth_password].length > 0
  used_auth_type='login'
  repo_uri = URI.parse(prepared_repository_url)
  
  # set the userinfo
  repo_uri.userinfo = "#{options[:auth_username]}:#{options[:auth_password]}"
  # 'serialize'
  prepared_repository_url = repo_uri.to_s
else
  # Auth: No Authentication information found - trying without authentication
end

# do clone
git_checkout_parameter = 'master'
# git_branch_parameter = ""
if options[:commit_hash] and options[:commit_hash].length > 0
  git_checkout_parameter = options[:commit_hash]
elsif options[:tag] and options[:tag].length > 0
  # since git 1.8.x tags can be specified as "branch" too ( http://git-scm.com/docs/git-clone )
  #  [!] this will create a detached head, won't switch to a branch!
  # git_branch_parameter = "--single-branch --branch #{options[:tag]}"
  git_checkout_parameter = options[:tag]
elsif options[:branch] and options[:branch].length > 0
  # git_branch_parameter = "--single-branch --branch #{options[:branch]}"
  git_checkout_parameter = options[:branch]
else
  # git_branch_parameter = "--no-single-branch"
  puts " [!] No checkout parameter found, will use 'master'"
end



$options = options
$prepared_repository_url = prepared_repository_url
$git_checkout_parameter = git_checkout_parameter
$this_script_path = File.expand_path('.')

class String
  def prepend_lines_with(prepend_with_string)
    return self.gsub(/^.*$/, prepend_with_string.to_s+'\&')
  end
end

def write_formatted_output_to_file(file_path)
  File.open("#{file_path}", "w") { |f|
    f.puts('# Commit Hash')
    f.puts
    commit_hash_str = `git log -1 --format="%H"`
    f.puts "    #{commit_hash_str.chomp}"
    f.puts
    f.puts('# Commit Log')
    f.puts
    commit_log_str = `git log -n 1 --tags --branches --remotes --format="fuller"`
    commit_log_str = commit_log_str.prepend_lines_with('    ')
    f.puts commit_log_str
  }
end

def do_clone()
  # first delete the destination folder - for git, especially if it's a retry
  return false unless system(%Q{rm -rf "#{$options[:clone_destination_dir]}"})
  # (re-)create
  return false unless system(%Q{mkdir -p "#{$options[:clone_destination_dir]}"})

  is_clone_success = false
  Dir.chdir($options[:clone_destination_dir]) do
    begin
      unless system(%Q{git init})
        raise 'Could not init git repository'
      end

      unless system(%Q{GIT_ASKPASS=echo GIT_SSH="#{$this_script_path}/ssh_no_prompt.sh" git remote add origin "#{$prepared_repository_url}"})
        raise 'Could not add remote'
      end

      unless system(%Q{GIT_ASKPASS=echo GIT_SSH="#{$this_script_path}/ssh_no_prompt.sh" git fetch})
        raise 'Could not fetch from repository'
      end

      unless system("git checkout #{$git_checkout_parameter}")
        raise 'Could not fetch from repository'
      end

      unless system(%Q{GIT_ASKPASS=echo GIT_SSH="#{$this_script_path}/ssh_no_prompt.sh" git submodule update --init --recursive})
        raise 'Could not fetch from repository'
      end


      formatted_output_file_path = $options[:formatted_output_file_path]
      if formatted_output_file_path
        write_formatted_output_to_file(formatted_output_file_path)
      end

      is_clone_success = true
    rescue => ex
      puts "Error: #{ex}"
    end
  end

  unless is_clone_success
    # delete it
    system(%Q{rm -rf "#{$options[:clone_destination_dir]}"})
  end

  return is_clone_success
end

is_clone_success = do_clone()
puts "Clone Is Success?: #{is_clone_success}"

if options[:private_key_file_path]
  puts " (i) Removing private key file: #{options[:private_key_file_path]}"
  system(%Q{rm -P #{options[:private_key_file_path]}})
end

exit (is_clone_success ? 0 : 1)


