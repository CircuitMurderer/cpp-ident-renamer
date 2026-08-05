# frozen_string_literal: true

require "minitest/autorun"
require_relative "../build"

class BuildScriptTest < Minitest::Test
  def test_pinned_toolchain_versions
    assert_equal "18.1.8", DEFAULT_LLVM_VERSION
    assert_equal "0.16.0", DEFAULT_ZIG_VERSION
    assert_equal "5.10", ZIG_SUPPORTED_LINUX_KERNEL
  end

  def test_linux_x64_asset_targets_ubuntu_18_04
    asset = DEFAULT_ASSETS.fetch("linux-x86_64")

    assert_equal "clang+llvm-18.1.8-x86_64-linux-gnu-ubuntu-18.04.tar.xz", asset.fetch("name")
    assert_equal 1_044_930_068, asset.fetch("size")
    assert_equal "54ec30358afcc9fb8aa74307db3046f5187f9fb89fb37064cdde906e062ebf36", asset.fetch("sha256")
    assert_equal "2.27", MIN_GLIBC_BY_TARGET.fetch("linux-x86_64")
  end

  def test_kylin_v10_glibc_meets_the_runtime_baseline
    minimum = MIN_GLIBC_BY_TARGET.fetch("linux-x86_64").split(".").map(&:to_i)

    assert version_at_least?([2, 28], minimum)
    refute version_at_least?([2, 26], minimum)
  end

  def test_zig_linux_kernel_baseline
    minimum = ZIG_SUPPORTED_LINUX_KERNEL.split(".").map(&:to_i)

    assert version_at_least?([5, 10], minimum)
    assert version_at_least?([6, 6], minimum)
    refute version_at_least?([4, 19], minimum)
  end

  def test_release_url_escapes_the_plus_sign
    asset = DEFAULT_ASSETS.fetch("linux-x86_64")

    assert_equal(
      "https://github.com/llvm/llvm-project/releases/download/llvmorg-18.1.8/clang%2Bllvm-18.1.8-x86_64-linux-gnu-ubuntu-18.04.tar.xz",
      release_url(DEFAULT_LLVM_VERSION, asset.fetch("name"))
    )
  end

  def test_linux_x64_offline_aliases
    %w[x64 x86_64 linux-x64 linux-x86_64].each do |name|
      assert_equal "linux-x86_64", normalize_offline_target(name)
    end
  end

  def test_clean_preserves_installed_toolchains_by_default
    targets = clean_targets(remove_toolchains: false)

    assert_includes targets, DOWNLOAD_ROOT
    assert_includes targets, ZIG_CACHE_ROOT
    assert_includes targets, ZIG_OUTPUT_ROOT
    assert_includes targets, DIST_ROOT
    refute_includes targets, TOOLS_ROOT
    refute_includes targets, LLVM_ROOT
    refute_includes targets, ZIG_ROOT
  end

  def test_clean_all_removes_the_tools_root
    targets = clean_targets(remove_toolchains: true)

    assert_includes targets, TOOLS_ROOT
    refute_includes targets, DOWNLOAD_ROOT
  end

  def test_finds_the_clang_resource_directory
    Dir.mktmpdir("cpp-ident-renamer-resource-") do |prefix|
      expected = File.join(prefix, "lib", "clang", "18")
      FileUtils.mkdir_p(File.join(expected, "include"))
      FileUtils.touch(File.join(expected, "include", "stddef.h"))

      assert_equal expected, clang_resource_dir(prefix)
    end
  end

  def test_rejects_an_llvm_prefix_without_builtin_headers
    Dir.mktmpdir("cpp-ident-renamer-resource-") do |prefix|
      error = assert_raises(BootstrapError) { clang_resource_dir(prefix) }

      assert_includes error.message, "include/stddef.h"
    end
  end
end
