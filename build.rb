#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "net/http"
require "open3"
require "openssl"
require "pathname"
require "rbconfig"
require "shellwords"
require "tmpdir"
require "timeout"
require "uri"

ROOT = File.expand_path(__dir__)
TOOLS_ROOT = File.join(ROOT, ".tools")
LLVM_ROOT = File.join(TOOLS_ROOT, "llvm")
ZIG_ROOT = File.join(TOOLS_ROOT, "zig")
DOWNLOAD_ROOT = File.join(TOOLS_ROOT, "downloads")
OFFLINE_MANIFEST_PATH = File.join(TOOLS_ROOT, "offline-manifest.json")
DIST_ROOT = File.join(ROOT, "dist")
DEFAULT_LLVM_VERSION = "22.1.6"
DEFAULT_ZIG_VERSION = "0.16.0"
DEFAULT_OFFLINE_TARGET = "linux-x86_64"

OFFLINE_TARGET_ALIASES = {
  "x64" => "linux-x86_64",
  "x86_64" => "linux-x86_64",
  "linux-x64" => "linux-x86_64",
  "linux-x86_64" => "linux-x86_64",
  "arm64" => "linux-aarch64",
  "aarch64" => "linux-aarch64",
  "linux-arm64" => "linux-aarch64",
  "linux-aarch64" => "linux-aarch64"
}.freeze

OFFLINE_PROJECT_ENTRIES = %w[
  .gitignore
  README.md
  build.rb
  build.zig
  build.zig.zon
  cpp-ident-renamer.toml
  cpp-ident-renamer.toml.example
  src
  test
  zls.build.json
].freeze

# These values are pinned to the official LLVM 22.1.6 release so libclang and
# clangd can use the same version across every supported platform.
DEFAULT_ASSETS = {
  "linux-x86_64" => {
    "name" => "LLVM-22.1.6-Linux-X64.tar.xz",
    "size" => 1_937_446_204,
    "sha256" => "c5ac8ef89ca39d30cb32e9b83772f995dd891c685ebc188d593c943a64d5f8b5"
  },
  "linux-aarch64" => {
    "name" => "LLVM-22.1.6-Linux-ARM64.tar.xz",
    "size" => 1_770_949_840,
    "sha256" => "b67817634e8e1c2632dfc056af14d61b94f8e6502f4e557560eea227aa22ce37"
  },
  "darwin-aarch64" => {
    "name" => "LLVM-22.1.6-macOS-ARM64.tar.xz",
    "size" => 1_480_006_836,
    "sha256" => "8059d9d9eeb059c30d812b4a37291888f8dcba04d2b5ace61fd12d2904eaa0e9"
  }
}.freeze

# Pinned from the official Zig 0.16.0 download index.
OFFLINE_ZIG_ASSETS = {
  "linux-x86_64" => {
    "name" => "zig-x86_64-linux-0.16.0.tar.xz",
    "size" => 55_478_392,
    "sha256" => "70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00",
    "url" => "https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz"
  },
  "linux-aarch64" => {
    "name" => "zig-aarch64-linux-0.16.0.tar.xz",
    "size" => 51_211_944,
    "sha256" => "ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17",
    "url" => "https://ziglang.org/download/0.16.0/zig-aarch64-linux-0.16.0.tar.xz"
  }
}.freeze

class BootstrapError < StandardError; end

def say(message)
  $stdout.puts("[cpp-ident-renamer] #{message}")
  $stdout.flush
end

def platform_key
  os = RbConfig::CONFIG.fetch("host_os")
  cpu = RbConfig::CONFIG.fetch("host_cpu")

  os_name = if os =~ /linux/i
              "linux"
            elsif os =~ /darwin|mac os/i
              "darwin"
            else
              raise BootstrapError, "Unsupported operating system #{os.inspect}; supported systems are Linux and macOS Apple Silicon"
            end

  cpu_name = case cpu.downcase
             when "x86_64", "amd64"
               "x86_64"
             when "aarch64", "arm64", "arm64e"
               "aarch64"
             else
               raise BootstrapError, "Unsupported CPU #{cpu.inspect}; supported architectures are x86_64 and ARM64"
             end

  key = "#{os_name}-#{cpu_name}"
  unless DEFAULT_ASSETS.key?(key)
    raise BootstrapError, "No supported official LLVM binary package is available for #{key}"
  end

  key
end

def normalize_offline_target(value)
  target = OFFLINE_TARGET_ALIASES[value.to_s.downcase]
  return target if target

  supported = %w[linux-x64 linux-arm64].join(", ")
  raise BootstrapError, "Unsupported offline target #{value.inspect}; supported targets: #{supported}"
end

def offline_target_label(target)
  target == "linux-x86_64" ? "linux-x64" : "linux-arm64"
end

def offline_bundle_basename(target)
  "cpp-ident-renamer-offline-#{offline_target_label(target)}"
end

def release_url(version, asset_name)
  escaped_name = URI.encode_www_form_component(asset_name).gsub("+", "%20")

  "https://github.com/llvm/llvm-project/releases/download/llvmorg-#{version}/#{escaped_name}"
end

def http_each_response(url, headers = {})
  uri = URI.parse(url)
  redirects = 0

  loop do
    http = Net::HTTP::Proxy(:ENV).new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = 30
    http.read_timeout = 120

    request = Net::HTTP::Get.new(uri.request_uri)
    request["User-Agent"] = "cpp-ident-renamer-bootstrap/#{DEFAULT_LLVM_VERSION}"
    request["Accept-Encoding"] = "identity"
    headers.each { |name, value| request[name] = value }

    redirected_to = nil
    result = nil
    http.start do |connection|
      connection.request(request) do |response|
        if response.is_a?(Net::HTTPRedirection)
          location = response["location"]
          raise BootstrapError, "Download redirect is missing a Location header: #{uri}" unless location

          redirected_to = URI.join(uri.to_s, location)
        else
          result = yield(response, uri)
        end
      end
    end
    return result unless redirected_to

    redirects += 1
    raise BootstrapError, "Too many download redirects: #{url}" if redirects > 10

    uri = redirected_to
  end
rescue SocketError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError => error
  raise BootstrapError, "Network request failed for #{uri}: #{error.message}"
end

def read_offline_manifest
  return nil unless File.file?(OFFLINE_MANIFEST_PATH)

  manifest = JSON.parse(File.read(OFFLINE_MANIFEST_PATH))
  unless manifest["format"] == 1 &&
      manifest["project"] == "cpp-ident-renamer" &&
      manifest["target"].is_a?(String)
    raise BootstrapError, "Invalid offline bundle manifest: #{OFFLINE_MANIFEST_PATH}"
  end

  manifest
rescue JSON::ParserError => error
  raise BootstrapError, "Offline bundle manifest is not valid JSON: #{error.message}"
end

def manifest_asset(component, version, key)
  manifest = read_offline_manifest
  return nil unless manifest && manifest["target"] == key

  entry = manifest[component]
  return nil unless entry.is_a?(Hash) && entry["version"] == version && entry["platform"] == key

  name = entry["name"].to_s
  size = entry["size"]
  checksum = entry["sha256"].to_s.downcase

  unless File.basename(name) == name && name.end_with?(".tar.xz")
    raise BootstrapError, "Invalid #{component} archive name in the offline manifest"
  end
  unless size.is_a?(Integer) && size.positive?
    raise BootstrapError, "Invalid #{component} archive size in the offline manifest"
  end
  unless checksum.match?(/\A[0-9a-f]{64}\z/)
    raise BootstrapError, "Invalid #{component} SHA-256 in the offline manifest"
  end

  {
    "name" => name,
    "size" => size,
    "sha256" => checksum,
    "url" => entry["url"].to_s
  }
end

def custom_archive_asset(url, checksum, label)
  unless checksum && checksum.match?(/\A[0-9a-fA-F]{64}\z/)
    raise BootstrapError, "#{label} URL requires a 64-character hexadecimal SHA-256"
  end

  uri = URI.parse(url)
  unless %w[http https].include?(uri.scheme) && uri.host
    raise BootstrapError, "#{label} URL only supports HTTP or HTTPS URLs with a host name"
  end

  name = File.basename(uri.path)
  raise BootstrapError, "The custom #{label} archive must be a .tar.xz file" unless name.end_with?(".tar.xz")

  { "name" => name, "size" => nil, "sha256" => checksum.downcase, "url" => url }
rescue URI::InvalidURIError => error
  raise BootstrapError, "Invalid #{label} download URL: #{error.message}"
end

def resolve_asset(key, options)
  custom_url = options[:llvm_url]
  custom_sha256 = options[:llvm_sha256]

  if custom_url
    return custom_archive_asset(custom_url, custom_sha256, "LLVM")
  end

  if options[:offline]
    bundled_asset = manifest_asset("llvm", DEFAULT_LLVM_VERSION, key)
    return bundled_asset if bundled_asset
  end

  asset = DEFAULT_ASSETS.fetch(key).dup
  asset["url"] = release_url(DEFAULT_LLVM_VERSION, asset.fetch("name"))
  asset
end

def resolve_zig_asset(options, target)
  custom_url = options[:zig_url]
  return OFFLINE_ZIG_ASSETS.fetch(target).dup unless custom_url

  custom_archive_asset(custom_url, options[:zig_sha256], "Zig")
end

def sha256(path)
  Digest::SHA256.file(path).hexdigest
end

def quarantine(path, reason)
  return unless File.exist?(path)

  destination = "#{path}.#{reason}-#{Time.now.utc.strftime('%Y%m%d%H%M%S')}"
  File.rename(path, destination)

  say("Preserved suspicious file as #{destination}")
end

def verify_file(path, asset)
  return false unless File.file?(path)

  expected_size = asset["size"]
  return false if expected_size && File.size(path) != expected_size

  sha256(path) == asset.fetch("sha256")
end

def download_asset(asset, options)
  FileUtils.mkdir_p(DOWNLOAD_ROOT)
  archive = File.join(DOWNLOAD_ROOT, asset.fetch("name"))
  partial = "#{archive}.part"

  if verify_file(archive, asset)
    say("Using verified download cache #{archive}")
    return archive
  elsif File.exist?(archive)
    quarantine(archive, "bad-checksum")
  end

  if options[:offline]
    raise BootstrapError, "No verified download cache is available in offline mode: #{archive}"
  end

  if verify_file(partial, asset)
    File.rename(partial, archive)
    return archive
  end

  expected_size = asset["size"]
  if File.exist?(partial) && expected_size && File.size(partial) > expected_size
    quarantine(partial, "oversized")
  end

  offset = File.exist?(partial) ? File.size(partial) : 0
  say("Downloading #{asset.fetch('url')}")
  say("Resuming from byte #{offset}") if offset.positive?

  headers = offset.positive? ? { "Range" => "bytes=#{offset}-" } : {}
  downloaded = offset
  last_report = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  http_each_response(asset.fetch("url"), headers) do |response, uri|
    append = response.is_a?(Net::HTTPPartialContent) && offset.positive?
    unless append || response.is_a?(Net::HTTPSuccess)
      raise BootstrapError, "Failed to download LLVM: HTTP #{response.code} #{uri}"
    end

    if append
      range = response["content-range"].to_s
      unless range.start_with?("bytes #{offset}-")
        raise BootstrapError, "The server returned an unexpected resume range: #{range.inspect}"
      end
    elsif offset.positive?
      say("The server does not support resuming; restarting the download")
      downloaded = 0
    end

    mode = append ? "ab" : "wb"

    File.open(partial, mode) do |file|
      response.read_body do |chunk|
        file.write(chunk)
        downloaded += chunk.bytesize

        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        next if now - last_report < 2

        if expected_size
          percent = downloaded * 100.0 / expected_size
          $stdout.print("\r[cpp-ident-renamer] %.1f%% (%d / %d MiB)" % [percent, downloaded / 1_048_576, expected_size / 1_048_576])
        else
          $stdout.print("\r[cpp-ident-renamer] Downloaded %d MiB" % (downloaded / 1_048_576))
        end
        $stdout.flush
        last_report = now
      end
    end
  end
  $stdout.puts

  if expected_size && File.size(partial) != expected_size
    raise BootstrapError, "Download size mismatch: got #{File.size(partial)}, expected #{expected_size}; the .part file was retained for resuming"
  end

  actual_sha256 = sha256(partial)
  unless actual_sha256 == asset.fetch("sha256")
    quarantine(partial, "bad-checksum")
    raise BootstrapError, "LLVM archive SHA-256 mismatch: got #{actual_sha256}"
  end

  File.rename(partial, archive)
  say("SHA-256 verification passed")

  archive
end

def inspect_archive!(archive)
  top_level = nil
  entries = 0
  status = nil

  Open3.popen3("tar", "-tf", archive) do |stdin, stdout, stderr, wait_thread|
    stdin.close
    stdout.each_line do |line|
      path = line.strip.sub(%r{\A\./}, "")
      next if path.empty?

      parts = path.split("/")
      if path.start_with?("/") || parts.include?("..")
        Process.kill("TERM", wait_thread.pid) rescue nil
        raise BootstrapError, "Archive contains an unsafe path: #{path.inspect}"
      end

      top_level ||= parts.first
      if parts.first != top_level
        Process.kill("TERM", wait_thread.pid) rescue nil
        raise BootstrapError, "Archive does not have a single top-level directory; refusing to extract"
      end

      entries += 1
    end

    error_text = stderr.read
    status = wait_thread.value
    raise BootstrapError, "Unable to inspect archive: #{error_text.strip}" unless status.success?
  end

  raise BootstrapError, "Archive is empty" if entries.zero?

  top_level
end

def shared_libclang(prefix)
  library_dir = File.join(prefix, "lib")
  candidates = [
    File.join(library_dir, "libclang.so"),
    File.join(library_dir, "libclang.dylib")
  ] + Dir[File.join(library_dir, "libclang.so.*")] +
      Dir[File.join(library_dir, "libclang.*.dylib")]

  candidates.find { |path| File.file?(path) && path !~ /\.a\z/ }
end

def validate_prefix!(prefix, run_clang: true)
  absolute = File.expand_path(prefix)
  required = [
    File.join(absolute, "bin", "clang"),
    File.join(absolute, "include", "clang-c", "Index.h")
  ]

  missing = required.reject { |path| File.file?(path) }
  missing << File.join(absolute, "lib", "libclang.{so,dylib}") unless shared_libclang(absolute)

  unless missing.empty?
    raise BootstrapError, "Incomplete LLVM prefix #{absolute}; missing:\n  #{missing.join("\n  ")}"
  end

  return absolute unless run_clang

  output, status = Open3.capture2e(File.join(absolute, "bin", "clang"), "--version")
  unless status.success?
    raise BootstrapError, "Local clang cannot run, possibly because glibc or the architecture is incompatible:\n#{output}"
  end

  absolute
end

def extract_asset(archive, target, force)
  validate_prefix!(target) if File.directory?(target) && !force
  return target if File.directory?(target) && !force

  FileUtils.mkdir_p(LLVM_ROOT)
  inspect_archive!(archive)

  staging = Dir.mktmpdir(".extract-", LLVM_ROOT)
  backup = nil

  begin
    command = ["tar", "-xJf", archive, "-C", staging, "--strip-components", "1"]
    say("+ #{Shellwords.join(command)}")
    success = system(*command)
    raise BootstrapError, "Failed to extract LLVM" unless success

    validate_prefix!(staging)

    if File.exist?(target) || File.symlink?(target)
      backup = "#{target}.previous-#{Time.now.utc.strftime('%Y%m%d%H%M%S')}"
      File.rename(target, backup)
      say("Moved the previous installation to #{backup}")
    end

    File.rename(staging, target)
  rescue StandardError
    File.rename(backup, target) if backup && File.exist?(backup) && !File.exist?(target)
    raise
  ensure
    FileUtils.rm_rf(staging) if File.exist?(staging)
  end

  target
end

def validate_zig_prefix!(prefix, expected_version = DEFAULT_ZIG_VERSION)
  absolute = File.expand_path(prefix)
  executable = File.join(absolute, "zig")

  unless File.file?(executable) && File.executable?(executable)
    raise BootstrapError, "Incomplete Zig prefix #{absolute}; missing executable: #{executable}"
  end

  output, status = Open3.capture2e(executable, "version")
  unless status.success?
    raise BootstrapError, "Local Zig cannot run, possibly because glibc or the architecture is incompatible:\n#{output}"
  end
  unless output.strip == expected_version
    raise BootstrapError, "Expected Zig #{expected_version}, but #{executable} reports #{output.strip.inspect}"
  end

  executable
end

def extract_zig_asset(archive, target, force)
  return validate_zig_prefix!(target) if File.directory?(target) && !force

  FileUtils.mkdir_p(ZIG_ROOT)
  inspect_archive!(archive)

  staging = Dir.mktmpdir(".extract-", ZIG_ROOT)
  backup = nil

  begin
    command = ["tar", "-xJf", archive, "-C", staging, "--strip-components", "1"]
    say("+ #{Shellwords.join(command)}")
    success = system(*command)
    raise BootstrapError, "Failed to extract Zig" unless success

    validate_zig_prefix!(staging)

    if File.exist?(target) || File.symlink?(target)
      backup = "#{target}.previous-#{Time.now.utc.strftime('%Y%m%d%H%M%S')}"
      File.rename(target, backup)
      say("Moved the previous Zig installation to #{backup}")
    end

    File.rename(staging, target)
  rescue StandardError
    File.rename(backup, target) if backup && File.exist?(backup) && !File.exist?(target)
    raise
  ensure
    FileUtils.rm_rf(staging) if File.exist?(staging)
  end

  validate_zig_prefix!(target)
end

def activate_install(target)
  current = File.join(LLVM_ROOT, "current")
  if File.directory?(current) && !File.symlink?(current)
    raise BootstrapError, "#{current} is a real directory and cannot be safely replaced with a version symlink"
  end

  relative_target = Pathname.new(target).relative_path_from(Pathname.new(LLVM_ROOT)).to_s
  temporary = "#{current}.tmp-#{Process.pid}"

  FileUtils.rm_f(temporary)
  File.symlink(relative_target, temporary)
  File.rename(temporary, current)

  current
ensure
  FileUtils.rm_f(temporary) if defined?(temporary) && File.symlink?(temporary)
end

def install_local_llvm(options)
  key = platform_key
  target = File.join(LLVM_ROOT, "#{DEFAULT_LLVM_VERSION}-#{key}")
  lock_path = File.join(TOOLS_ROOT, "llvm-install.lock")

  FileUtils.mkdir_p(TOOLS_ROOT)

  File.open(lock_path, "w") do |lock|
    say("Waiting for the installation lock") unless lock.flock(File::LOCK_EX | File::LOCK_NB)
    lock.flock(File::LOCK_EX)

    if File.directory?(target) && !options[:force]
      validate_prefix!(target)
      return activate_install(target)
    end

    asset = resolve_asset(key, options)
    archive = download_asset(asset, options)
    extract_asset(archive, target, options[:force])

    current = activate_install(target)
    say("Installed local LLVM at #{target}")

    current
  end
end

def selected_prefix(options, auto_install: true)
  if options[:llvm_prefix]
    return validate_prefix!(options[:llvm_prefix])
  end

  version_target = File.join(LLVM_ROOT, "#{DEFAULT_LLVM_VERSION}-#{platform_key}")
  if File.directory?(version_target)
    validate_prefix!(version_target)
    return activate_install(version_target)
  end

  return nil unless auto_install

  install_local_llvm(options)
end

def install_bundled_zig(options)
  key = platform_key
  asset = manifest_asset("zig", DEFAULT_ZIG_VERSION, key)
  unless asset
    raise BootstrapError, "No bundled Zig #{DEFAULT_ZIG_VERSION} archive is available for #{key}"
  end

  target = File.join(ZIG_ROOT, "#{DEFAULT_ZIG_VERSION}-#{key}")
  return validate_zig_prefix!(target) if File.directory?(target) && !options[:force]

  archive = download_asset(asset, options.merge(offline: true))
  executable = extract_zig_asset(archive, target, options[:force])
  say("Installed local Zig at #{target}")

  executable
end

def selected_zig(options, auto_install: true)
  configured = ENV["ZIG"]
  return validate_zig_command!(configured) if configured

  key = platform_key
  local_prefix = File.join(ZIG_ROOT, "#{DEFAULT_ZIG_VERSION}-#{key}")
  return validate_zig_prefix!(local_prefix) if File.directory?(local_prefix)

  if auto_install && manifest_asset("zig", DEFAULT_ZIG_VERSION, key)
    return install_bundled_zig(options)
  end

  return validate_zig_command!("zig") if executable_on_path?("zig")

  raise BootstrapError, "Zig #{DEFAULT_ZIG_VERSION} was not found; use --pack-offline to include it or set ZIG=/path/to/zig"
end

def validate_zig_command!(command)
  unless command && executable_on_path?(command)
    raise BootstrapError, "Zig executable was not found: #{command.inspect}"
  end

  output, status = Open3.capture2e(command, "version")
  raise BootstrapError, "Zig failed to run: #{output}" unless status.success?
  unless output.strip == DEFAULT_ZIG_VERSION
    raise BootstrapError, "Expected Zig #{DEFAULT_ZIG_VERSION}, but #{command} reports #{output.strip.inspect}"
  end

  command
end

def copy_or_link(source, destination)
  File.link(source, destination)
rescue Errno::EXDEV, Errno::EPERM, Errno::EACCES, NotImplementedError
  FileUtils.cp(source, destination, preserve: true)
end

def bundle_asset_entry(asset, archive, version, target)
  {
    "version" => version,
    "platform" => target,
    "name" => asset.fetch("name"),
    "size" => File.size(archive),
    "sha256" => asset.fetch("sha256"),
    "url" => asset.fetch("url")
  }
end

def pack_offline(options)
  target = normalize_offline_target(options[:offline_target])
  bundle_basename = offline_bundle_basename(target)
  llvm_asset = resolve_asset(target, options)
  zig_asset = resolve_zig_asset(options, target)

  say("Preparing offline bundle for #{offline_target_label(target)}")
  llvm_archive = download_asset(llvm_asset, options)
  zig_archive = download_asset(zig_asset, options)

  FileUtils.mkdir_p(DIST_ROOT)
  staging_root = Dir.mktmpdir(".offline-pack-", DIST_ROOT)
  bundle_root = File.join(staging_root, bundle_basename)
  output = File.join(DIST_ROOT, "#{bundle_basename}.tar")
  partial_output = "#{output}.part-#{Process.pid}"

  begin
    FileUtils.mkdir_p(bundle_root)
    OFFLINE_PROJECT_ENTRIES.each do |entry|
      source = File.join(ROOT, entry)
      raise BootstrapError, "Cannot package missing project entry: #{source}" unless File.exist?(source)

      FileUtils.cp_r(source, File.join(bundle_root, entry), preserve: true)
    end

    bundle_downloads = File.join(bundle_root, ".tools", "downloads")
    FileUtils.mkdir_p(bundle_downloads)
    copy_or_link(llvm_archive, File.join(bundle_downloads, llvm_asset.fetch("name")))
    copy_or_link(zig_archive, File.join(bundle_downloads, zig_asset.fetch("name")))

    manifest = {
      "format" => 1,
      "project" => "cpp-ident-renamer",
      "target" => target,
      "llvm" => bundle_asset_entry(llvm_asset, llvm_archive, DEFAULT_LLVM_VERSION, target),
      "zig" => bundle_asset_entry(zig_asset, zig_archive, DEFAULT_ZIG_VERSION, target)
    }
    File.write(
      File.join(bundle_root, ".tools", "offline-manifest.json"),
      JSON.pretty_generate(manifest) + "\n"
    )
    File.write(
      File.join(bundle_root, "OFFLINE-README.txt"),
      <<~TEXT
        cpp-ident-renamer offline bundle
        Target: #{offline_target_label(target)}
        Included: LLVM #{DEFAULT_LLVM_VERSION} and Zig #{DEFAULT_ZIG_VERSION}

        This directory is network-independent. Build with:

          ruby build.rb build

        The build script verifies both archives, installs them under .tools,
        and uses the bundled Zig and LLVM automatically.
      TEXT
    )

    command = ["tar", "-cf", partial_output, "-C", staging_root, bundle_basename]
    say("+ #{Shellwords.join(command)}")
    raise BootstrapError, "Failed to create offline bundle" unless system(*command)

    File.rename(partial_output, output)
    bundle_sha256 = sha256(output)
    File.write("#{output}.sha256", "#{bundle_sha256}  #{File.basename(output)}\n")

    say("Offline bundle created: #{output}")
    say("Bundle SHA-256: #{bundle_sha256}")
    output
  ensure
    FileUtils.rm_rf(staging_root) if File.exist?(staging_root)
    FileUtils.rm_f(partial_output) if File.exist?(partial_output)
  end
end

def executable_on_path?(name)
  return File.executable?(name) if name.include?(File::SEPARATOR)

  ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |directory|
    File.executable?(File.join(directory, name)) && !File.directory?(File.join(directory, name))
  end
end

def run_command!(command)
  say("+ #{Shellwords.join(command)}")
  success = system(*command, chdir: ROOT)

  return if success

  status = $CHILD_STATUS || $?
  code = status && status.exitstatus

  raise BootstrapError, "Command failed#{code ? ", exit code #{code}" : ""}: #{Shellwords.join(command)}"
end

def zig_with_prefix(prefix, arguments)
  option = "-Dllvm-prefix=#{File.expand_path(prefix)}"
  result = arguments.dup
  separator = result.index("--")

  separator ? result.insert(separator, option) : result.push(option)

  result
end

def doctor(options)
  say("Project directory: #{ROOT}")
  say("Platform: #{platform_key}")
  say("Ruby: #{RUBY_DESCRIPTION}")

  begin
    zig = selected_zig(options, auto_install: false)
    output, = Open3.capture2e(zig, "version")
    say("Zig: #{output.strip} at #{zig}")
  rescue BootstrapError => error
    bundled_zig = manifest_asset("zig", DEFAULT_ZIG_VERSION, platform_key)
    if bundled_zig
      say("Zig: bundled archive is ready and will be installed during build")
    else
      say("Zig: #{error.message}")
    end
  end

  prefix = selected_prefix(options, auto_install: false)
  unless prefix
    say("Local LLVM: not installed; run ruby build.rb install")
    return
  end

  prefix = validate_prefix!(prefix)
  output, = Open3.capture2e(File.join(prefix, "bin", "clang"), "--version")

  say("LLVM prefix: #{prefix}")
  say("Clang: #{output.lines.first.to_s.strip}")
  say("libclang: #{shared_libclang(prefix)}")
end

def usage
  <<~TEXT
    Usage: ruby build.rb <command> [options] [Zig arguments]

    Commands:
      install    Download, verify, and extract project-local toolchains
      build      Install LLVM when needed, then run zig build (default)
      run        Build and run the tool; example: ruby build.rb run -- check -p build
      test       Run unit, end-to-end, and fix safety tests
      doctor     Show Ruby, Zig, and local LLVM status without downloading

    Installation options:
      --llvm-prefix PATH    Use an existing LLVM without downloading; also available as CPP_IDENT_RENAMER_LLVM_PREFIX
      --offline             Use only a previously verified download cache
      --force               Preserve the old installation as .previous-* and reinstall
      --llvm-url URL        Use a custom archive; requires --llvm-sha256
      --llvm-sha256 HEX     SHA-256 of the custom archive
      --pack-offline [TARGET]
                            Create an offline bundle; TARGET is linux-x64 (default) or linux-arm64
      --offline-target NAME Set the target separately from --pack-offline
      --zig-url URL         Override the Zig archive used by --pack-offline
      --zig-sha256 HEX      SHA-256 of the custom Zig archive

    Other arguments are passed to Zig. For run, arguments before `--` are Zig build
    arguments and arguments after `--` are passed to cpp-ident-renamer.
  TEXT
end

def parse_arguments(arguments)
  commands = %w[install bootstrap build run test doctor help]
  command = if arguments.empty? || arguments.first.start_with?("-")
              "build"
            else
              candidate = arguments.shift
              raise BootstrapError, "Unknown command #{candidate.inspect}\n\n#{usage}" unless commands.include?(candidate)
              candidate
            end
  command = "install" if command == "bootstrap"

  options = {
    llvm_prefix: ENV["CPP_IDENT_RENAMER_LLVM_PREFIX"],
    llvm_url: ENV["CPP_IDENT_RENAMER_LLVM_URL"],
    llvm_sha256: ENV["CPP_IDENT_RENAMER_LLVM_SHA256"],
    zig_url: ENV["CPP_IDENT_RENAMER_ZIG_URL"],
    zig_sha256: ENV["CPP_IDENT_RENAMER_ZIG_SHA256"],
    offline_target: ENV.fetch("CPP_IDENT_RENAMER_OFFLINE_TARGET", DEFAULT_OFFLINE_TARGET),
    offline: File.file?(OFFLINE_MANIFEST_PATH),
    pack_offline: false,
    force: false
  }

  passthrough = []
  index = 0

  while index < arguments.length
    argument = arguments[index]
    if argument == "--"
      passthrough.concat(arguments[index..-1])
      break
    end

    case argument
    when "--llvm-prefix", "--llvm-url", "--llvm-sha256", "--zig-url", "--zig-sha256", "--offline-target"
      value = arguments[index + 1]
      raise BootstrapError, "#{argument} requires a value" unless value
      options[argument.delete_prefix("--").tr("-", "_").to_sym] = value
      index += 2
      next
    when /\A--llvm-prefix=(.*)\z/
      options[:llvm_prefix] = Regexp.last_match(1)
    when /\A--llvm-url=(.*)\z/
      options[:llvm_url] = Regexp.last_match(1)
    when /\A--llvm-sha256=(.*)\z/
      options[:llvm_sha256] = Regexp.last_match(1)
    when /\A--zig-url=(.*)\z/
      options[:zig_url] = Regexp.last_match(1)
    when /\A--zig-sha256=(.*)\z/
      options[:zig_sha256] = Regexp.last_match(1)
    when /\A--offline-target=(.*)\z/
      options[:offline_target] = Regexp.last_match(1)
    when /\A--pack-offline=(.*)\z/
      options[:pack_offline] = true
      options[:offline_target] = Regexp.last_match(1)
    when "--offline"
      options[:offline] = true
    when "--pack-offline"
      options[:pack_offline] = true
      candidate = arguments[index + 1]
      if candidate && !candidate.start_with?("-")
        options[:offline_target] = candidate
        index += 1
      end
    when "--force"
      options[:force] = true
    else
      passthrough << argument
    end

    index += 1
  end

  [command, options, passthrough]
end

begin
  command, options, passthrough = parse_arguments(ARGV.dup)

  if command == "help"
    puts usage
    exit 0
  end

  if options[:pack_offline]
    pack_offline(options)
    exit 0
  end

  if command == "doctor"
    doctor(options)
    exit 0
  end

  prefix = if options[:llvm_prefix]
             validate_prefix!(options[:llvm_prefix])
           else
             install_local_llvm(options)
           end

  if command == "install"
    zig = selected_zig(options) if read_offline_manifest
    say("Activated LLVM: #{File.expand_path(prefix)}")
    say("Activated Zig: #{zig}") if zig
    say("You can now run ruby build.rb build")
    exit 0
  end

  zig = selected_zig(options)

  case command
  when "build"
    run_command!([zig, "build"] + zig_with_prefix(prefix, passthrough))
  when "test"
    steps = %w[test test-e2e test-fix]
    run_command!([zig, "build"] + steps + zig_with_prefix(prefix, passthrough))
  when "run"
    separator = passthrough.index("--")
    if separator
      build_arguments = passthrough[0...separator]
      program_arguments = passthrough[(separator + 1)..-1]
    else
      build_arguments = []
      program_arguments = passthrough
    end

    command_line = [zig, "build", "run"] + zig_with_prefix(prefix, build_arguments)
    command_line += ["--"] + program_arguments
    run_command!(command_line)
  end
rescue BootstrapError => error
  warn("[cpp-ident-renamer] Error: #{error.message}")
  exit 1
rescue Interrupt
  warn("\n[cpp-ident-renamer] Interrupted; the unfinished download remains as .part and will resume next time")
  exit 130
end
