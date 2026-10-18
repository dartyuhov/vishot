# Run with `brew ruby`; uses Homebrew's real DSL, not a substitute parser.
require "json"
require "cask/cask_loader"
require "simulate_system"

path = Pathname(ARGV.fetch(0)).realpath
metadata = %i[arm intel].to_h do |arch|
  info = Homebrew::SimulateSystem.with(os: :sonoma, arch: arch) do
    Cask::CaskLoader::FromPathLoader.new(path).load(config: nil).to_h
  end
  [arch, info]
end
puts JSON.generate(metadata)
