#!/usr/bin/env rspec

require_relative "test_helper"

require "installation/update_repository"
require "uri"
require "pathname"

describe Installation::UpdateRepository do
  TEMP_DIR = Pathname.new(__FILE__).dirname.join("tmp")

  Yast.import "Pkg"

  subject(:repo) { Installation::UpdateRepository.new(uri) }

  let(:uri) { URI("http://updates.opensuse.org/sles12") }
  let(:repo_id) { 1 }
  let(:download_path) { TEMP_DIR.join("download") }
  let(:updates_path) { TEMP_DIR.join("mounts") }
  let(:tmpdir) { TEMP_DIR.join("tmp") }
  let(:probed) { "RPMMD" }
  let(:packages) { [] }

  before do
    allow(Yast::Pkg).to receive(:RepositoryProbe).with(uri.to_s, "/").and_return(probed)
    allow(Yast::Pkg).to receive(:RepositoryAdd)
      .with(hash_including("base_urls" => [uri.to_s]))
      .and_return(repo_id)
    allow(Yast::Pkg).to receive(:SourceRefreshNow).with(repo_id).and_return(true)
    allow(Yast::Pkg).to receive(:SourceLoad).and_return(true)
  end

  describe "#packages" do
    after { FileUtils.rm_rf(TEMP_DIR) }

    let(:package) do
      { "name" => "pkg1", "path" => "./x86_64/pkg1-3.1.x86_64.rpm", "source" => repo_id }
    end

    let(:from_other_repo) do
      { "name" => "pkg2", "path" => "./x86_64/pkg2-3.1.x86_64.rpm", "source" => repo_id + 1 }
    end

    before do
      allow(Yast::Pkg).to receive(:ResolvableProperties).with("", :package, "")
        .and_return(packages)
    end

    context "when the repository type can't be determined" do
      let(:probed) { "NONE" }

      it "raises a NotValidRepo error" do
        expect { subject.packages }
          .to raise_error(Installation::UpdateRepository::NotValidRepo)
      end
    end

    context "when the repository can't be probed" do
      let(:probed) { nil }

      it "raises a CouldNotProbeRepo error" do
        expect { subject.packages }
          .to raise_error(Installation::UpdateRepository::CouldNotProbeRepo)
      end
    end

    context "when repository cannot be refreshed" do
      before do
        allow(Yast::Pkg).to receive(:SourceRefreshNow).and_return(nil)
      end

      it "raises a CouldNotRefreshRepo error" do
        expect { subject.packages }
          .to raise_error(Installation::UpdateRepository::CouldNotRefreshRepo)
      end
    end

    context "when the repo does not have packages" do
      let(:packages) { [from_other_repo] }

      it "returns an empty array" do
        expect(repo.packages).to eq([])
      end
    end

    context "when the source contains packages" do
      let(:other_package) do
        { "name" => "pkg0", "path" => "./x86_64/pkg0-3.1.x86_64.rpm", "source" => repo_id }
      end

      let(:packages) { [package, from_other_repo, other_package] }

      it "returns update repository packages sorted by name" do
        expect(repo.packages).to eq([other_package, package])
      end
    end
  end

  describe "#fetch" do
    around do |example|
      FileUtils.mkdir_p([download_path, updates_path, tmpdir])
      example.run
      FileUtils.rm_rf(TEMP_DIR)
    end

    let(:package) do
      { "name" => "pkg1", "path" => "./x86_64/pkg1-3.1.x86_64.rpm", "source" => repo_id }
    end

    let(:libzypp_package_path) { "/var/adm/tmp/pkg1-3.1.x86_64.rpm" }
    let(:package_path) { "/var/adm/tmp/pkg1-3.1.x86_64.rpm" }
    let(:tempfile) { double("tempfile", close: true, path: package_path, unlink: true) }
    let(:downloader) { double("Packages::PackageDownloader", download: nil) }
    let(:extractor) { double("Packages::PackageExtractor", extract: nil) }

    before do
      allow(repo).to receive(:add_repo).and_return(repo_id)
      allow(repo).to receive(:packages).and_return([package])
      allow(Dir).to receive(:mktmpdir).and_yield(tmpdir.to_s)
      allow(Packages::PackageDownloader).to receive(:new).with(repo_id, package["name"]).and_return(downloader)
      allow(Packages::PackageExtractor).to receive(:new).with(tempfile.path.to_s).and_return(extractor)
      allow(Tempfile).to receive(:new).and_return(tempfile)
    end

    it "builds one squashed filesystem by package" do
      # Download
      expect(downloader).to receive(:download).with(tempfile.path.to_s)

      # Extract
      expect(extractor).to receive(:extract).with(tmpdir.to_s)

      # Squash
      expect(Yast::SCR).to receive(:Execute)
        .with(Yast::Path.new(".target.bash_output"), /mksquashfs.+#{tmpdir} .+\/yast_000/)
        .and_return("exit" => 0, "stdout" => "", "stderr" => "")

      repo.fetch(download_path)
    end

    context "when a package can't be retrieved" do
      before do
        expect(downloader).to receive(:download).and_raise(Packages::PackageDownloader::FetchError)
      end

      it "clear downloaded files and raises a CouldNotFetchUpdate error" do
        expect(repo).to receive(:remove_update_files)
        expect { repo.fetch(download_path) }
          .to raise_error(Installation::UpdateRepository::CouldNotFetchUpdate)
      end
    end

    context "when a package can't be extracted" do
      it "clear downloaded files and raises a CouldNotFetchUpdate error" do
        expect(extractor).to receive(:extract).and_raise(Packages::PackageExtractor::ExtractionFailed)

        expect(repo).to receive(:remove_update_files)
        expect { repo.fetch(download_path) }
          .to raise_error(Installation::UpdateRepository::CouldNotFetchUpdate)
      end
    end

    context "when a package can't be squashed" do
      it "clear downloaded files and raises a CouldNotFetchUpdate error" do
        allow(Yast::SCR).to receive(:Execute)
          .with(Yast::Path.new(".target.bash_output"), /mksquash/)
          .and_return("exit" => 1, "stdout" => "", "stderr" => "")

        expect(repo).to receive(:remove_update_files)
        expect { repo.fetch(download_path) }
          .to raise_error(Installation::UpdateRepository::CouldNotFetchUpdate)
      end
    end
  end

  describe "#remove_update_files" do
    let(:update_file) { Pathname.new("yast_001") }

    it "removes downloaded files and clear update_files" do
      allow(repo).to receive(:update_files).and_return([update_file])
      expect(FileUtils).to receive(:rm_f).with(update_file)
      expect(repo.update_files).to receive(:clear)
      repo.remove_update_files
    end
  end

  describe "#apply" do
    let(:update_path) { Pathname("/download/yast_000") }
    let(:mount_point) { updates_path.join("yast_0000") }
    let(:file) { double("file") }

    before do
      allow(repo).to receive(:update_files).and_return([update_path])
      allow(Installation::UpdateRepository::INSTSYS_PARTS_PATH).to receive(:open).and_yield(file)
      allow(FileUtils).to receive(:mkdir_p).with(mount_point)
    end

    it "mounts and adds files/dir" do
      # mount
      expect(Yast::SCR).to receive(:Execute)
        .with(Yast::Path.new(".target.bash_output"), /mount.+#{update_path}.+#{mount_point}/)
        .and_return("exit" => 0)
      # adddir
      expect(Yast::SCR).to receive(:Execute)
        .with(Yast::Path.new(".target.bash_output"), /adddir #{mount_point} \//)
        .and_return("exit" => 0)

      expect(file).to receive(:puts)
      repo.apply(updates_path)
    end

    it "adds mounted filesystem to instsys.parts file" do
      allow(Yast::SCR).to receive(:Execute).and_return("exit" => 0)
      expect(file).to receive(:puts).with(%r{\Adownload/yast_000.+yast_0000})
      repo.apply(updates_path)
    end

    context "when a squashed package can't be mounted" do
      it "raises a CouldNotMountUpdate error" do
        allow(Yast::SCR).to receive(:Execute).and_return("exit" => 0)
        allow(Yast::SCR).to receive(:Execute)
          .with(Yast::Path.new(".target.bash_output"), /mount/)
          .and_return("exit" => 1, "stdout" => "", "stderr" => "")
        expect { repo.apply(updates_path) }
          .to raise_error(Installation::UpdateRepository::CouldNotMountUpdate)
      end
    end

    context "when files can't be added to inst-sys" do
      it "raises a CouldNotBeApplied error" do
        allow(Yast::SCR).to receive(:Execute).with(any_args).and_return("exit" => 0)
        allow(Yast::SCR).to receive(:Execute)
          .with(Yast::Path.new(".target.bash_output"), /adddir/)
          .and_return("exit" => 1, "stdout" => "", "stderr" => "")
        expect { repo.apply(updates_path) }
          .to raise_error(Installation::UpdateRepository::CouldNotBeApplied)
      end
    end
  end

  describe "#cleanup" do
    it "deletes and releases the repository" do
      expect(Yast::Pkg).to receive(:SourceDelete).with(repo_id)
      expect(Yast::Pkg).to receive(:SourceReleaseAll)
      expect(Yast::Pkg).to receive(:SourceSaveAll)

      subject.cleanup
    end
  end

  describe "#user_defined?" do
    context "when origin is :user" do
      subject(:repo) { Installation::UpdateRepository.new(uri, :user) }

      it "returns true" do
        expect(repo).to be_user_defined
      end
    end

    context "when origin is :default" do
      subject(:repo) { Installation::UpdateRepository.new(uri, :default) }

      it "returns false" do
        expect(repo).to_not be_user_defined
      end
    end

    context "when origin is not specified" do
      it "returns false" do
        expect(repo).to_not be_user_defined
      end
    end
  end

  describe "#remote?" do
    context "when is a remote URL according to libzypp" do
      it "returns true" do
        expect(Yast::Pkg).to receive(:UrlSchemeIsRemote).with("http")
          .and_call_original
        expect(repo).to be_remote
      end
    end

    context "when is not a remote URL according to libzypp" do
      let(:uri) { URI("cd:/?device=sr0") }

      it "returns false" do
        expect(Yast::Pkg).to receive(:UrlSchemeIsRemote).with("cd")
          .and_call_original
        expect(repo).to_not be_remote
      end
    end
  end

  describe "#inspect" do
    let(:uri) { URI("http://user:123456@updates.suse.com") }

    it "does not contain sensitive information" do
      expect(repo.inspect).to_not include("123456")
    end
  end

  describe "#to_s" do
    let(:uri) { URI("http://user:123456@updates.suse.com") }

    it "does not contain sensitive information" do
      expect(repo.to_s).to_not include("123456")
    end
  end
end
