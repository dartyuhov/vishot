# Run with brew ruby. Exercises the real app artifact, without downloads, taps,
# Caskroom receipts, or changing /Applications. All paths belong to a test root.
require "cask/cask_loader"
require "cask/config"
require "cask/artifact/app"
require "fileutils"

cask_path, stage_path, appdir = ARGV.map { |path| Pathname(path).realpath }
config = Cask::Config.new(explicit: { appdir: appdir.to_s })
cask = Cask::CaskLoader::FromPathLoader.new(cask_path).load(config: config)
# Ignore any saved configuration for a user's installed Vishot cask.
cask.config = config
# Redirect staging only; use Homebrew's actual DSL, target resolution, move,
# permission preservation, and source-link behavior for the installation.
cask.instance_variable_set(:@caskroom_path, stage_path.parent)
expected_stage = cask.staged_path
raise "Unexpected staged path #{expected_stage}" unless expected_stage == stage_path
artifact = cask.artifacts.find { |item| item.is_a?(Cask::Artifact::App) }
raise "Expected app-only cask" unless artifact && cask.artifacts.count == 1
raise "Target escaped test appdir: #{artifact.target} vs #{appdir}" unless artifact.target.expand_path == appdir/"Vishot.app"
artifact.install_phase
raise "Installed helper missing" unless (artifact.target/"Contents/Helpers/vishot").executable?
