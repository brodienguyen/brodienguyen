# Vendors the Simple Icons (CC0 1.0) logos named in data/profile.json's stack into
# icons/simple-icons.json, so the build needs no network for them.
# Run with `mise run icons` after adding or changing a stack icon.

require "json"
require "net/http"

VERSION = "16.33.0"
ROOT = File.expand_path("..", __dir__)
CDN = "https://cdn.jsdelivr.net/npm/simple-icons@#{VERSION}"

def get(path)
  res = Net::HTTP.get_response(URI("#{CDN}/#{path}"))
  raise "#{path}: HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)

  res.body
end

data = JSON.parse(File.read(File.join(ROOT, "data/profile.json")), symbolize_names: true)
# Marks Simple Icons lacks are vendored by hand in icons/brands.json, so they are skipped here.
brands = JSON.parse(File.read(File.join(ROOT, "icons/brands.json"))).fetch("icons").keys
slugs = data[:stack].flat_map { |layer| layer[:items].filter_map { |item| item[:icon] } }.uniq.sort - brands
colours = JSON.parse(get("data/simple-icons.json"), symbolize_names: true).to_h { |icon| [icon[:slug], icon[:hex]] }

icons = slugs.to_h do |slug|
  svg = get("icons/#{slug}.svg")
  path = svg[/ d="([^"]+)"/, 1] or raise "#{slug}: no path in icon"
  [slug, { hex: colours.fetch(slug), path: }]
end

dir = File.join(ROOT, "icons")
Dir.mkdir(dir) unless Dir.exist?(dir)
File.write(File.join(dir, "simple-icons.json"), JSON.pretty_generate({ source: "simple-icons@#{VERSION}", license: "CC0-1.0", icons: }) + "\n")
puts "vendored #{icons.size} icons from simple-icons@#{VERSION}"
