# Builds README.md and its SVG panels from data/profile.json in the portfolio's blueprint style.
#
#   ruby bin/build.rb        static panels in assets/, live panels in live/, and README.md
#   ruby bin/build.rb live   only the live panels (the daily workflow publishes live/)
#
# Live panels (upstream timeline, contribution city) read the GitHub GraphQL API with
# GITHUB_TOKEN, or `gh auth token` locally. PROFILE_REPO names the repository the README
# loads images from (default brodienguyen/brodienguyen).

require "date"
require "erb"
require "json"
require "net/http"

ROOT = File.expand_path("..", __dir__)
DATA = JSON.parse(File.read(File.join(ROOT, "data/profile.json")), symbolize_names: true)
ICONS = JSON.parse(File.read(File.join(ROOT, "icons/simple-icons.json")), symbolize_names: true).fetch(:icons).transform_keys(&:to_s)
BRANDS = JSON.parse(File.read(File.join(ROOT, "icons/brands.json")), symbolize_names: true).fetch(:icons).transform_keys(&:to_s)
REPO = ENV.fetch("PROFILE_REPO", "brodienguyen/brodienguyen")

THEMES = {
  "dark" => { canvas: "#0b1622", surface: "#0f1e2e", line: "#4cc9f0", ink: "#e6eef6", muted: "#8aa0b4", accent: "#4cc9f0", ok: "#4ade80",
              face: "#4cc9f0", side: "#1d7fa6", top: "#a5e6f8", window: "#fde68a",
              term: "#08111b", violet: "#a78bfa" }
}.freeze

WIDE = 880
PHONE = 400
GAP = 8 # sheet space below each card; heights then snap to the grid
GRID = 16
SHEET = { false => 32, true => 16 } # side margin of the sheet, wide and phone, a multiple of GRID
SANS = "'Space Grotesk', 'Inter', ui-sans-serif, -apple-system, 'Segoe UI', Helvetica, Arial, sans-serif"
MONO = "'JetBrains Mono', ui-monospace, SFMono-Regular, Menlo, Consolas, monospace"
MONO_EM = 0.61 # monospace advance as a fraction of font size, rounded up so text never overflows
SANS_EM = 0.54

def esc(text) = ERB::Util.html_escape(text)
def mono_w(text, size, tracking: 0) = text.length * size * (MONO_EM + tracking)
def mono_fit(width, size) = (width / (size * MONO_EM)).floor
def sans_fit(width, size) = (width / (size * SANS_EM)).floor
def thousands(n) = n.to_s.reverse.scan(/\d{1,3}/).join(",").reverse

def wrap(text, max)
  text.split.each_with_object([+""]) do |word, lines|
    lines << +"" if !lines.last.empty? && lines.last.length + word.length + 1 > max
    lines.last << (lines.last.empty? ? word : " #{word}")
  end
end

# Drawing primitives -------------------------------------------------------

def text(x, y, str, c, size: 13, fill: :ink, font: :mono, weight: nil, anchor: nil, css: nil)
  attrs = +%(x="#{x.round(1)}" y="#{y.round(1)}" class="#{css || font}" font-size="#{size}" fill="#{c[fill]}")
  attrs << %( font-weight="#{weight}") if weight
  attrs << %( text-anchor="#{anchor}") if anchor
  %(<text #{attrs}>#{esc(str)}</text>)
end

def label(x, y, str, c, accent: false, anchor: nil)
  attrs = +%(x="#{x.round(1)}" y="#{y.round(1)}" class="#{accent ? "eyebrow" : "label"}")
  attrs << %( text-anchor="#{anchor}") if anchor
  %(<text #{attrs}>#{esc(str)}</text>)
end

def hairline(x1, y1, x2, y2, c, opacity: 0.22, dash: nil)
  %(<line x1="#{x1.round(1)}" y1="#{y1.round(1)}" x2="#{x2.round(1)}" y2="#{y2.round(1)}" stroke="#{c[:line]}" stroke-opacity="#{opacity}"#{dash ? %( stroke-dasharray="#{dash}") : ""}/>)
end

def arrow(x1, y1, x2, y2, c)
  %(<line x1="#{x1.round(1)}" y1="#{y1.round(1)}" x2="#{x2.round(1)}" y2="#{y2.round(1)}" stroke="#{c[:accent]}" stroke-width="1.5" marker-end="url(#arrow)"/>)
end

def ticks(x, y, w, h, c)
  len = 10
  a = x + 0.75
  b = y + 0.75
  r = x + w - 0.75
  btm = y + h - 0.75
  ["M#{a} #{b + len}V#{b}H#{a + len}", "M#{r - len} #{b}H#{r}V#{b + len}",
   "M#{a} #{btm - len}V#{btm}H#{a + len}", "M#{r - len} #{btm}H#{r}V#{btm - len}"]
    .map { |d| %(<path d="#{d}" fill="none" stroke="#{c[:line]}" stroke-opacity="0.65" stroke-width="1.5"/>) }.join
end

def card(w, h, c, grid: false)
  out = +%(<rect x="0.5" y="0.5" width="#{w - 1}" height="#{h - 1}" fill="#{c[:surface]}" stroke="#{c[:line]}" stroke-opacity="0.22"/>)
  out << %(<rect x="1" y="1" width="#{w - 2}" height="#{h - 2}" fill="url(#grid)"/>) if grid
  out << ticks(0, 0, w, h, c)
end

def box(x, y, w, h, title, sub, c, strong: false)
  out = +%(<rect x="#{x.round(1)}" y="#{y.round(1)}" width="#{w.round(1)}" height="#{h}" rx="3" fill="#{c[:surface]}" stroke="#{strong ? c[:accent] : c[:line]}" stroke-opacity="#{strong ? 0.9 : 0.4}"/>)
  out << label(x + 12, y + 20, title, c, accent: strong)
  out << text(x + 12, y + 38, sub, c, size: 11.5, fill: :muted) if sub
  out
end

def chip(x, y, str, c, colour: :line, size: 12, height: 26)
  w = mono_w(str, size) + 20
  [%(<rect x="#{x.round(1)}" y="#{y.round(1)}" width="#{w.round(1)}" height="#{height}" rx="3" fill="#{c[:surface]}" stroke="#{c[colour]}" stroke-opacity="#{colour == :line ? 0.35 : 0.8}"/>) +
    text(x + 10, y + (height / 2.0) + (size * 0.36), str, c, size: size, fill: colour == :line ? :ink : colour), w]
end

def document(w, h, c, alt, body, css = "", grid_x: 0, round: nil)
  r = 12
  sheet = case round
          when :top then "M0 #{h}V#{r}Q0 0 #{r} 0H#{w - r}Q#{w} 0 #{w} #{r}V#{h}Z"
          when :bottom then "M0 0H#{w}V#{h - r}Q#{w} #{h} #{w - r} #{h}H#{r}Q0 #{h} 0 #{h - r}Z"
          else "M0 0H#{w}V#{h}H0Z"
          end
  <<~SVG
    <svg xmlns="http://www.w3.org/2000/svg" width="#{w}" height="#{h}" viewBox="0 0 #{w} #{h}" role="img" aria-label="#{esc(alt)}">
      <defs>
        <pattern id="grid" width="16" height="16" patternUnits="userSpaceOnUse" patternTransform="translate(#{grid_x} 0)"><path d="M16 0H0V16" fill="none" stroke="#{c[:line]}" stroke-opacity="0.07"/></pattern>
        <marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0 0L10 5L0 10z" fill="#{c[:accent]}"/></marker>
      </defs>
      <style>
        .sans { font-family: #{SANS}; }
        .mono { font-family: #{MONO}; }
        .label { font-family: #{MONO}; font-size: 11px; letter-spacing: 0.14em; fill: #{c[:muted]}; }
        .eyebrow { font-family: #{MONO}; font-size: 12px; font-weight: 600; letter-spacing: 0.14em; fill: #{c[:accent]}; }
        #{css}
      </style>
      <path d="#{sheet}" fill="#{c[:canvas]}"/>
      <path d="#{sheet}" fill="url(#grid)"/>
      #{body}
    </svg>
  SVG
end

# Static panels: each returns [height, body, css] for a width, theme and layout

# The intro is drawn the way `bn screenshot` photographs a terminal: the same window,
# title bar and prompt, in bn-term's Dracula palette.
SCREENSHOT = {
  window: "#0D1117", bar: "#161B22", bar_line: "#21262D", title: "#8B949E",
  fg: "#C9D1D9", command: "#E6EDF3", purple: "#BD93F9", pink: "#FF79C6", cyan: "#8BE9FD", green: "#50FA7B",
  muted: "#6272A4", stripe: "#313345", surface: "#44475A", orange: "#FFB86C", yellow: "#F1FA8C"
}.freeze
SCREENSHOT_MONO = "'SF Mono', 'JetBrains Mono', Menlo, Consolas, 'DejaVu Sans Mono', monospace"

def term_text(str) = esc(str).gsub(" ", " ") # non-breaking, so column padding survives

def tty(x, y, size, fill, content, weight: nil, css: "tty")
  %(<text x="#{x.round(1)}" y="#{y.round(1)}" class="#{css}" font-size="#{size}" fill="#{fill}"#{weight ? %( font-weight="#{weight}") : ""}>#{content}</text>)
end

# Dracula colours for Ruby, as bn-term's terminals show it.
RUBY_TOKENS = /(?<str>"(?:[^"\\]|\\.)*")|(?<sym>%[iw]\[[^\]]*\]|:[a-z_]+\b|\b[a-z_]+:(?=\s))|(?<num>\b\d+\b)|(?<const>\b[A-Z]\w*)|(?<kw>\b(?:require|do|end|puts|class|def|module)\b)|(?<dsl>^\s*(?!(?:def|class|end|module)\b)[a-z_]+(?=[ (]))|(?<meth>(?<=\.)[a-z_]+[!?]?)/

def ruby_tspans(line, s)
  colours = { str: s[:yellow], sym: s[:purple], num: s[:purple], const: s[:cyan], kw: s[:pink], meth: s[:green], dsl: s[:green] }
  out = +""
  rest = line
  while (m = RUBY_TOKENS.match(rest))
    out << %(<tspan fill="#{s[:fg]}">#{term_text(m.pre_match)}</tspan>) unless m.pre_match.empty?
    kind = m.names.find { m[it] }.to_sym
    out << %(<tspan fill="#{colours[kind]}">#{term_text(m[0])}</tspan>)
    rest = m.post_match
  end
  out << %(<tspan fill="#{s[:fg]}">#{term_text(rest)}</tspan>) unless rest.empty?
  out
end

# The intro is a bn CLI command, written the way bn-cli commands are: a Bn::BaseCommand with
# a desc and a call method drawing bn-term output. It is a demo, typed out before it runs.
def whoami_source(intro)
  width = intro[:fields].map { |verb, _| verb.length }.max
  area_w = intro[:table].map { |area, _| area.length }.max
  lines = ["class Bn::Commands::Whoami < Bn::BaseCommand", %(  desc "Who is #{intro[:name].split.first}?"), "",
           "  def call(**)", %(    header "#{intro[:name]}",), %(      "#{intro[:role]}"), %(    spin "loading profile"), ""]
  lines += intro[:fields].map { |verb, text| %(    say #{":#{verb},".ljust(width + 2)} "#{text}") }
  lines += ["", "    table %w[Area Stack],"]
  lines += intro[:table].map.with_index do |(area, stack), i|
    %(      #{"#{area.downcase}:".ljust(area_w + 1)} "#{stack}"#{"," if i < intro[:table].length - 1})
  end
  lines += ["", %(    progress "shipping"), "    badges #{intro[:tags].map { ":#{it.downcase}" }.join(", ")}",
            %(    done "#{intro[:motto].join(" ")}"), "  end", "end"]
  lines.join("\n") + "\n"
end

# The opening terminal, on a loop: whoami.rb types itself, the screen clears, the script
# runs and bn-term's output appears (spinner, header box, status lines, table, progress,
# badges, callout), holds, then everything starts again. Every element has its own
# keyframes on one shared cycle, so the loop stays in step. Without motion the panel
# shows the finished output.
def header_panel(w, _c, phone)
  s = SCREENSHOT
  intro = DATA[:intro]
  code = whoami_source(intro).lines.map(&:chomp)
  bar = 34
  pad = phone ? 14 : 22
  gutter = 4
  code_size = [((w - (2 * pad)) / ((code.map(&:length).max + gutter) * MONO_EM)).floor(1), 12].min
  code_lh = (code_size * 1.42).round(1)
  code_char = code_size * MONO_EM
  size = phone ? 10.5 : 12.5
  char = size * MONO_EM
  lh = (size * 1.6).round(1)
  palette = { accent: s[:purple], green: s[:green], yellow: s[:yellow], cyan: s[:cyan], pink: s[:pink], orange: s[:orange] }

  # Typing schedule, in seconds.
  t = 0.6
  typed = code.map do |line|
    next nil if line.strip.empty?

    dur = [(line.length * 0.01), 0.08].max
    slot = [t, t + dur]
    t += dur + 0.03
    slot
  end
  clear_at = t + 1.0
  run_from = clear_at + 0.3
  run_to = run_from + 0.6
  out_at = run_to + 0.3
  spin_for = 1.0
  step = 0.12

  # Output pieces in reading order: [svg, extra keyframes builder or nil].
  pieces = []
  prompt_y = bar + 18 + size
  cmd_x = pad + (2 * char)
  col_a = pad
  status_cols = 11 + intro[:fields].map { |_, value| value.length }.max
  col_b = phone ? pad : pad + ([status_cols, intro[:role].length + 6].max + 4) * char
  y = prompt_y + lh + 4
  spin_y = y
  y += lh + 6

  box = lambda do |x, lines, colour, pad_cols|
    inner = lines.map { |str, _| str.length }.max + (2 * pad_cols)
    bw = (inner + 2) * char
    bh = (lines.length + 1) * lh
    svg = +%(<rect x="#{(x + (char / 2)).round(1)}" y="#{(y - size - (lh / 2) + 3).round(1)}" width="#{(bw - char).round(1)}" height="#{(bh - 2).round(1)}" rx="4" fill="none" stroke="#{colour}"/>)
    lines.each_with_index do |(str, fill, weight), i|
      svg << tty(x + ((1 + pad_cols) * char), y + ((i + 0.5) * lh), size, fill, term_text(str), weight:)
    end
    pieces << svg
    y += bh + 4
  end

  # Column A: header box, status lines, badges.
  box.call(col_a, [[intro[:name], s[:purple], 700], [intro[:role], s[:muted], nil]], s[:purple], 2)
  intro[:fields].each_with_index do |(verb, value), i|
    colour = palette[intro[:colours][i % intro[:colours].length].to_sym]
    pieces << %(<text x="#{col_a}" y="#{y.round(1)}" class="tty" font-size="#{size}"><tspan fill="#{colour}">#{term_text(verb.rjust(10))}</tspan><tspan fill="#{s[:fg]}">#{term_text(" #{value}")}</tspan></text>)
    y += lh
  end
  y += lh / 2
  bx = col_a
  badges = +""
  intro[:tags].each_with_index do |tag, i|
    label_text = " #{tag} "
    bw = label_text.length * char
    badges << %(<rect x="#{bx.round(1)}" y="#{(y - size).round(1)}" width="#{bw.round(1)}" height="#{(size + 4).round(1)}" fill="#{palette[intro[:colours][i].to_sym]}"/>)
    badges << tty(bx, y, size, s[:window], term_text(label_text), weight: 700)
    bx += bw + char
  end
  pieces << badges
  col_a_bottom = y + lh

  # Column B: striped table, progress bar, closing callout.
  y = phone ? col_a_bottom + (lh / 2) : spin_y + lh + 6 + (size / 2)
  area_w = ([intro[:table].map { |a, _| a.length }.max, 4].max + 2) * char
  stack_w = ([intro[:table].map { |_, st| st.length }.max, 5].max + 2) * char
  table_w = area_w + stack_w
  top = y - size - 4
  rows = [["Area", "Stack"]] + intro[:table]
  table = +%(<rect x="#{col_b}" y="#{top.round(1)}" width="#{table_w.round(1)}" height="#{((rows.length * lh) + 10).round(1)}" rx="4" fill="none" stroke="#{s[:muted]}" stroke-opacity="0.8"/>)
  rows.each_with_index do |(area, stack), r|
    ry = y + (r * lh) + (r.positive? ? 6 : 0)
    table << %(<rect x="#{col_b + 1}" y="#{(ry - size - 2).round(1)}" width="#{(table_w - 2).round(1)}" height="#{lh}" fill="#{s[:stripe]}"/>) if r.positive? && r.even?
    fill = r.zero? ? s[:purple] : s[:fg]
    weight = r.zero? ? 700 : nil
    table << tty(col_b + char, ry, size, fill, term_text(area), weight:)
    table << tty(col_b + area_w + char, ry, size, fill, term_text(stack), weight:)
  end
  sep_y = (y + 6).round(1)
  table << %(<path d="M#{col_b} #{sep_y}H#{(col_b + table_w).round(1)}M#{(col_b + area_w).round(1)} #{top.round(1)}V#{(top + (rows.length * lh) + 10).round(1)}" stroke="#{s[:muted]}" stroke-opacity="0.8"/>)
  pieces << table
  y += (rows.length * lh) + 10 + lh

  label = "shipping"
  bar_x = col_b + ((label.length + 1) * char)
  bar_w = 22 * char
  progress_at = nil
  progress = +tty(col_b, y, size, s[:muted], label)
  # Blueprint-style segmented bar: outlined cells, filled in one ink colour as a clip opens.
  cell_y = (y - size + 1).round(1)
  cells = 22
  track = +""
  ink = +""
  cells.times do |i|
    cx = (bar_x + (i * char) + 0.75).round(1)
    track << %(<rect x="#{cx}" y="#{cell_y}" width="#{(char - 1.5).round(1)}" height="#{size}" fill="none" stroke="#{s[:cyan]}" stroke-opacity="0.35"/>)
    ink << %(<rect x="#{cx}" y="#{cell_y}" width="#{(char - 1.5).round(1)}" height="#{size}" fill="#{s[:cyan]}"/>)
  end
  progress << track
  progress << %(<clipPath id="prog"><rect class="fill" x="#{bar_x.round(1)}" y="#{cell_y - 1}" width="#{bar_w.round(1)}" height="#{size + 2}" FILLSTYLE/></clipPath>)
  progress << %(<g clip-path="url(#prog)">#{ink}</g>)
  progress << tty(bar_x + bar_w + char, y, size, s[:fg], "100%", weight: 700)
  pieces << progress
  progress_index = pieces.length - 1
  y += lh + (lh / 2) + 4

  saved_y = y
  y = phone ? y : saved_y
  box.call(col_b, [["✓ done", s[:green], 700]] + intro[:motto].map { [it, s[:fg], nil] }, s[:green], 1)
  end_prompt_y = [y, col_a_bottom + (phone ? 0 : 0)].max + 4
  out_bottom = end_prompt_y + 16

  hold = 9.0
  cycle = out_at + spin_for + (pieces.length * step) + 1.2 + hold
  pct = ->(sec) { format("%.3f", sec / cycle * 100) }
  frames = []
  seq = 0
  keyframes = lambda do |body|
    seq += 1
    frames << "@keyframes k#{seq} { #{body} }"
    "k#{seq}"
  end
  appear = lambda do |on, off = nil|
    off ||= cycle - 0.4
    keyframes.call("0%, #{pct.(on)}% { opacity: 0; } #{pct.(on + 0.15)}%, #{pct.(off)}% { opacity: 1; } #{pct.(off + 0.2)}%, 100% { opacity: 0; }")
  end
  flash = lambda do |on, off|
    keyframes.call("0%, #{pct.(on)}% { opacity: 0; } #{pct.(on + 0.001)}%, #{pct.(off)}% { opacity: 1; } #{pct.(off + 0.001)}%, 100% { opacity: 0; }")
  end
  anim = ->(name, timing = "linear") { %(style="animation: #{name} #{cycle.round(2)}s #{timing} infinite") }

  parts = []
  # Code screen.
  code_parts = []
  cy = bar + 18 + code_size
  code_parts << tty(pad, cy, code_size, s[:green], "❯") + tty(pad + (2 * code_char), cy, code_size, s[:command], "vim commands/whoami.rb", weight: 600)
  cy += code_lh + 6
  covers = []
  code.each_with_index do |line, i|
    code_parts << %(<text x="#{(pad + (2 * code_char)).round(1)}" y="#{cy.round(1)}" class="tty" font-size="#{code_size}" fill="#{s[:muted]}" fill-opacity="0.6" text-anchor="end">#{i + 1}</text>)
    if (slot = typed[i])
      lx = pad + (gutter * code_char)
      code_parts << %(<text x="#{lx.round(1)}" y="#{cy.round(1)}" class="tty" font-size="#{code_size}">#{ruby_tspans(line, s)}</text>)
      lw = ((line.length * code_char) + 2).ceil
      k = keyframes.call("0%, #{pct.(slot[0])}% { transform: translateX(0); } #{pct.(slot[1])}%, 100% { transform: translateX(#{lw}px); }")
      covers << %(<rect x="#{(lx - 3).round(1)}" y="#{(cy - code_size - 3).round(1)}" width="#{lw + 3}" height="#{code_lh + 2}" fill="#{s[:window]}" #{anim.(k, "steps(#{[line.length * 2, 2].max})")}/>)
    end
    cy += code_lh
  end
  code_bottom = cy
  parts << %(<g class="loop" #{anim.(appear.(0, clear_at))}>#{code_parts.join}) +
           %(<clipPath id="code"><rect x="#{pad}" y="#{bar}" width="#{w - (2 * pad)}" height="#{(code_bottom - bar).round(1)}"/></clipPath><g clip-path="url(#code)">#{covers.join}</g></g>)

  # Run screen: the command types, a spinner turns, then the output appears piece by piece.
  command = "bn whoami"
  cmd_w = ((command.length * char) + 2).ceil
  type_k = keyframes.call("0%, #{pct.(run_from + 0.1)}% { transform: translateX(0); } #{pct.(run_to)}%, 100% { transform: translateX(#{cmd_w}px); }")
  parts << %(<g class="out" #{anim.(appear.(run_from))}>) +
           tty(pad, prompt_y, size, s[:green], "❯") + tty(cmd_x, prompt_y, size, s[:command], command, weight: 600) +
           %(<clipPath id="cmd"><rect x="#{cmd_x.round(1)}" y="#{prompt_y - size - 2}" width="#{cmd_w}" height="#{lh}"/></clipPath>) +
           %(<g clip-path="url(#cmd)"><rect x="#{cmd_x.round(1)}" y="#{prompt_y - size - 2}" width="#{cmd_w}" height="#{lh}" fill="#{s[:window]}" #{anim.(type_k, "steps(#{command.length * 2})")}/></g></g>)

  spinner = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏]
  frame_len = 0.08
  (spin_for / frame_len).floor.times do |j|
    on = out_at + (j * frame_len)
    parts << %(<g class="loop" #{anim.(flash.(on, on + frame_len))}>#{tty(col_a, spin_y, size, s[:purple], spinner[j % spinner.length])}</g>)
  end
  done_at = out_at + spin_for
  parts << %(<g class="out" #{anim.(appear.(done_at))}>#{tty(col_a, spin_y, size, s[:green], "✓")}</g>)
  parts << %(<g class="out" #{anim.(appear.(out_at))}>#{tty(col_a + (2 * char), spin_y, size, s[:fg], "loading profile")}</g>)

  t = done_at + 0.2
  pieces.each_with_index do |svg, i|
    if i == progress_index
      fill_k = keyframes.call("0%, #{pct.(t)}% { transform: scaleX(0); } #{pct.(t + 1.0)}%, 100% { transform: scaleX(1); }")
      svg = svg.sub("FILLSTYLE", anim.(fill_k, "ease-out"))
      parts << %(<g class="out" #{anim.(appear.(t))}>#{svg}</g>)
      t += 1.2
    else
      parts << %(<g class="out" #{anim.(appear.(t))}>#{svg}</g>)
      t += step
    end
  end
  parts << %(<g class="out" #{anim.(appear.(t))}>#{tty(pad, end_prompt_y, size, s[:green], "❯")}) +
           %(<rect class="blink" x="#{cmd_x.round(1)}" y="#{end_prompt_y - size + 1}" width="#{(char * 0.9).round(1)}" height="#{size + 3}" fill="#{s[:fg]}"/></g>)

  win_h = ([code_bottom, out_bottom].max + 12).round
  window = %(<clipPath id="win"><rect width="#{w}" height="#{win_h}" rx="12"/></clipPath>) +
           %(<rect width="#{w}" height="#{win_h}" rx="12" fill="#{s[:window]}"/>) +
           %(<g clip-path="url(#win)"><rect width="#{w}" height="#{bar}" fill="#{s[:bar]}"/><path d="M0 #{bar - 0.5}H#{w}" stroke="#{s[:bar_line]}"/></g>) +
           %w[#FF5F57 #FEBC2E #28C840].each_with_index.map { |dot, i| %(<circle cx="#{20 + (i * 20)}" cy="#{bar / 2}" r="6" fill="#{dot}"/>) }.join +
           %(<text x="#{w / 2.0}" y="#{(bar / 2) + 4}" class="sans" font-size="12" fill="#{s[:title]}" text-anchor="middle">#{esc("#{intro[:user]}@#{intro[:host]} — zsh")}</text>) +
           %(<rect x="0.5" y="0.5" width="#{w - 1}" height="#{win_h - 1}" rx="12" fill="none" stroke="#ffffff" stroke-opacity="0.08"/>)

  css = <<~CSS
    .tty { font-family: #{SCREENSHOT_MONO}; }
    .loop { opacity: 0; }
    .fill { transform-box: fill-box; transform-origin: left center; }
    .blink { animation: blink 1.1s steps(1) infinite; }
    @keyframes blink { 50% { opacity: 0; } }
    #{frames.join("\n")}
    @media (prefers-reduced-motion: reduce) {
      .loop, .out, .loop *, .out * { animation: none !important; }
      .loop { opacity: 0; }
      .out { opacity: 1; }
      .fill { transform: none; }
    }
  CSS
  [win_h + GAP, window + parts.join, css]
end

def section_panel(number, title, note, w, c, phone)
  parts = [label(1, 30, "#{number} · #{title}", c, accent: true)]
  parts << label(w - 1, 30, note, c, anchor: "end") unless phone || note.nil?
  [48, parts.join]
end

# The platform's architecture, drawn from its README diagram: clients, the Rails monolith,
# its stores and the infrastructure underneath.
# Platforms agents can work in safely: agents run inside a harness of guardrails, and their
# work reaches production only through the quality gate. Commits loop along the lanes.
def agents_panel(w, c, phone)
  a = DATA[:agents]
  pad = phone ? 16 : 24
  parts = []
  y = pad + 30
  (phone ? a[:headline_short] : [a[:headline]]).each do |line|
    parts << text(pad, y, line, c, size: phone ? 20 : 26, font: :sans, weight: 700)
    y += phone ? 26 : 32
  end
  sub_size = phone ? 11 : 12.5
  wrap(a[:subline], mono_fit(w - (2 * pad), sub_size)).each do |line|
    parts << text(pad, y - 4, line, c, size: sub_size, fill: :muted)
    y += 18
  end
  y += phone ? 4 : 0

  lane_gap = phone ? 40 : 44
  lanes = a[:lanes]
  task_h = 50
  gate_w = phone ? ((w - (2 * pad) - 12) / 2.0) : 184
  ship_w = phone ? gate_w : 112

  if phone
    parts << box(pad, y, w - (2 * pad), task_h, "TASK", a[:task], c)
    parts << arrow(w / 2.0, y + task_h + 2, w / 2.0, y + task_h + 18, c)
    y += task_h + 30
    x1 = pad + 14
    x2 = w - pad - 14
    lane_top = y + 26
  else
    lane_top = y + 40
    task_x = pad
    task_w = 140
    ship_x = w - pad - ship_w
    gate_x = ship_x - 28 - gate_w
    x1 = task_x + task_w + 40
    x2 = gate_x - 40
    mid = lane_top + (((lanes.length - 1) * lane_gap) / 2.0)
    parts << box(task_x, mid - (task_h / 2.0), task_w, task_h, "TASK", a[:task], c)
    parts << box(gate_x, mid - (task_h / 2.0), gate_w, task_h, "QUALITY GATE", a[:gate], c, strong: true)
    parts << box(ship_x, mid - (task_h / 2.0), ship_w, task_h, "LIVE", a[:ship], c)
    parts << arrow(gate_x + gate_w + 2, mid, ship_x - 2, mid, c)
    parts << %(<circle class="beat" cx="#{(gate_x + gate_w - 14).round(1)}" cy="#{(mid - (task_h / 2.0) + 16).round(1)}" r="4" fill="#{c[:ok]}"/>)
  end

  track = x2 - x1
  lanes.each_with_index do |lane, i|
    ly = lane_top + (i * lane_gap)
    unless phone
      parts << %(<path d="M#{task_x + task_w} #{mid.round(1)}C#{task_x + task_w + 16} #{mid.round(1)} #{x1 - 16} #{ly} #{x1} #{ly}" fill="none" stroke="#{c[:line]}" stroke-opacity="0.45"/>)
      parts << %(<path d="M#{x2} #{ly}C#{x2 + 16} #{ly} #{gate_x - 16} #{mid.round(1)} #{gate_x} #{mid.round(1)}" fill="none" stroke="#{c[:line]}" stroke-opacity="0.45"/>)
    end
    parts << label(x1, ly - 9, "#{lane[:agent]} · #{lane[:tree]}", c)
    parts << hairline(x1, ly, x2, ly, c, opacity: 0.35, dash: "2 4")
    # Each lane carries two commits, half a loop apart; lanes are offset so they never sync.
    2.times do |k|
      delay = -((i * 1.3) + (k * 2.2)).round(2)
      parts << %(<rect class="commit" x="#{x1 - 5}" y="#{ly - 5}" width="10" height="10" rx="2" fill="#{c[:accent]}" ) +
               %(style="--len: #{track.round(1)}px; animation-delay: #{delay}s"/>)
    end
  end
  y = lane_top + ((lanes.length - 1) * lane_gap)
  hx = x1 - 14
  hy = lane_top - 30
  hw = track + 28
  hh = y - hy + 18
  parts << %(<rect class="rail" x="#{hx}" y="#{hy}" width="#{hw.round(1)}" height="#{hh}" rx="6" fill="#{c[:ok]}" fill-opacity="0.04" stroke="#{c[:ok]}" stroke-opacity="0.85" stroke-dasharray="6 4"/>)
  parts << %(<rect x="#{(hx + hw - 16 - mono_w(a[:harness], 10)).round(1)}" y="#{hy - 7}" width="#{(mono_w(a[:harness], 10) + 12).round(1)}" height="14" fill="#{c[:surface]}"/>)
  parts << text(hx + hw - 10, hy + 4, a[:harness], c, size: 10, fill: :ok, anchor: "end")
  y += 18

  if phone
    y += 2
    parts << arrow(w / 2.0, y, w / 2.0, y + 16, c)
    y += 22
    parts << box(pad, y, gate_w, task_h, "QUALITY GATE", a[:gate_short], c, strong: true)
    parts << box(pad + gate_w + 12, y, ship_w, task_h, "LIVE", a[:ship], c)
    parts << %(<circle class="beat" cx="#{(pad + gate_w - 14).round(1)}" cy="#{y + 16}" r="4" fill="#{c[:ok]}"/>)
    y += task_h + 18
  else
    y += 22
  end

  x = pad
  a[:values].each do |fact|
    chip_svg, cw = chip(x, y, fact, c, colour: :ok, size: phone ? 10.5 : 11.5, height: 24)
    if x + cw > w - pad
      x = pad
      y += 30
      chip_svg, cw = chip(x, y, fact, c, colour: :ok, size: phone ? 10.5 : 11.5, height: 24)
    end
    parts << chip_svg
    x += cw + 8
  end
  y += 24 + 22
  parts << label(pad, y, a[:caption], c)
  h = y + pad - 6
  css = <<~CSS
    .commit { animation: commit 4.4s linear infinite; }
    .beat { animation: beat 1.1s ease-in-out infinite; }
    .rail { animation: rail 1.6s linear infinite; }
    @keyframes rail { to { stroke-dashoffset: -20; } }
    @keyframes commit {
      0% { transform: translateX(0); opacity: 0; }
      8% { opacity: 1; }
      92% { opacity: 1; }
      100% { transform: translateX(var(--len)); opacity: 0; }
    }
    @keyframes beat { 50% { opacity: 0.25; } }
    @media (prefers-reduced-motion: reduce) { .commit, .beat, .rail { animation: none; } }
  CSS
  [h + GAP, card(w, h, c) + parts.join, css]
end

# What I build, end to end: the layers of a product I design and ship, with developer
# experience running alongside every one. A highlight walks down the layers like a request.
def capabilities_panel(w, c, phone)
  cap = DATA[:capabilities]
  pad = phone ? 16 : 24
  gap = 8
  parts = []
  y = pad + 10
  parts << label(pad, y, "FIG. 03 · WHAT I BUILD, END TO END", c)
  parts << label(w - pad, y, "ARCHITECTURE I DESIGN AND SHIP", c, anchor: "end") unless phone
  y += 18

  dx_w = phone ? 0 : 282
  band_w = w - (2 * pad) - (phone ? 0 : dx_w + 12)
  size = phone ? 11 : 12
  top = y
  layers = cap[:layers]
  beat = 1.1
  mids = []
  layers.each_with_index do |layer, i|
    lines = wrap(layer[:detail], mono_fit(band_w - 32, size))
    h = 30 + (lines.length * 17) + 4
    parts << %(<rect x="#{pad}" y="#{y}" width="#{band_w.round(1)}" height="#{h}" rx="3" fill="#{c[:surface]}" stroke="#{c[:line]}" stroke-opacity="0.35"/>)
    parts << %(<rect class="lit" x="#{pad}" y="#{y}" width="#{band_w.round(1)}" height="#{h}" rx="3" fill="#{c[:accent]}" fill-opacity="0.07" stroke="#{c[:accent]}" ) +
             %(style="animation-delay: #{(i * beat).round(2)}s; animation-duration: #{(layers.length * beat).round(2)}s"/>)
    parts << %(<rect x="#{pad}" y="#{y}" width="3" height="#{h}" fill="#{c[:accent]}"/>)
    mids << y + (h / 2.0)
    parts << label(pad + 16, y + 20, layer[:name], c, accent: true)
    lines.each_with_index { |line, k| parts << text(pad + 16, y + 38 + (k * 17), line, c, size:, fill: :muted) }
    y += h + gap
  end
  bottom = y - gap

  if phone
    y += 4
    # Each item is a problem (muted) and the fix I built (ink), one under the other.
    detail = wrap(cap[:dx][:detail], mono_fit(w - (2 * pad) - 32, size))
    h = 30 + (detail.length * 17) + 8 + (cap[:dx][:items].length * 36)
    parts << %(<rect x="#{pad}" y="#{y}" width="#{w - (2 * pad)}" height="#{h}" rx="3" fill="none" stroke="#{c[:ok]}" stroke-opacity="0.8" stroke-dasharray="4 3"/>)
    parts << label(pad + 16, y + 20, cap[:dx][:name], c)
    ty = y + 38
    detail.each do |line|
      parts << text(pad + 16, ty, line, c, size:, fill: :ok)
      ty += 17
    end
    ty += 8
    cap[:dx][:items].each do |problem, fix|
      parts << text(pad + 16, ty, problem, c, size: size - 1, fill: :muted)
      parts << text(pad + 16, ty + 16, "→ #{fix}", c, size:, fill: :ink)
      ty += 36
    end
    y += h
  else
    x = w - pad - dx_w
    parts << %(<rect x="#{x}" y="#{top}" width="#{dx_w}" height="#{bottom - top}" rx="3" fill="none" stroke="#{c[:ok]}" stroke-opacity="0.8" stroke-dasharray="4 3"/>)
    parts << label(x + 16, top + 22, cap[:dx][:name], c)
    ty = top + 46
    wrap(cap[:dx][:detail], mono_fit(dx_w - 32, size)).each do |line|
      parts << text(x + 16, ty, line, c, size:, fill: :ok)
      ty += 18
    end
    ty += 10
    # Spread the items down the box, so a short list doesn't leave a gap at the bottom.
    row = ((bottom - ty - 8) / cap[:dx][:items].length).clamp(36, 64)
    cap[:dx][:items].each do |problem, fix|
      parts << text(x + 16, ty, problem, c, size: size - 1, fill: :muted)
      parts << text(x + 16, ty + 16, "→ #{fix}", c, size:, fill: :ink)
      ty += row
    end
    # Arrows from the DX bar into each layer: it speeds up all of them.
    mids.each { |my| parts << arrow(x - 2, my, pad + band_w + 3, my, c) }
    y = bottom
  end

  y += 30
  parts << label(pad, y, cap[:caption], c)
  h = y + pad - 6
  css = <<~CSS
    .lit { opacity: 0; animation-name: lit; animation-timing-function: ease-in-out; animation-iteration-count: infinite; }
    @keyframes lit { 0% { opacity: 0; } 8% { opacity: 1; } 22% { opacity: 0; } 100% { opacity: 0; } }
    @media (prefers-reduced-motion: reduce) { .lit { animation: none; } }
  CSS
  [h + GAP, card(w, h, c) + parts.join, css]
end

def stack_panel(w, c, phone)
  pad = phone ? 16 : 24
  label_w = phone ? 0 : 120
  size = phone ? 11 : 12
  chip_h = phone ? 24 : 26
  parts = []
  chips = 0
  y = pad
  layers = DATA[:stack]
  layers.each_with_index do |layer, li|
    band_top = y
    y += 12
    if phone
      parts << label(pad + 14, y + 10, layer[:label], c, accent: true)
      y += 20
    end
    x = pad + label_w + 14
    layer[:items].each do |item|
      cw = mono_w(item[:name], size) + 44
      if x + cw > w - pad - 12
        x = pad + label_w + 14
        y += chip_h + 8
      end
      delay = (0.2 + (chips * 0.04)).round(2)
      chips += 1
      parts << %(<g class="pop" style="animation-delay: #{delay}s">) +
               %(<rect x="#{x.round(1)}" y="#{y}" width="#{cw.round(1)}" height="#{chip_h}" rx="3" fill="#{c[:surface]}" stroke="#{c[:line]}" stroke-opacity="0.35"/>) +
               logo(item, x + 10, y + ((chip_h - 14) / 2.0), 14, c) +
               text(x + 32, y + (chip_h / 2.0) + (size * 0.36), item[:name], c, size: size) + "</g>"
      x += cw + 8
    end
    y += chip_h + 12
    band_h = y - band_top
    opacity = (0.05 + (0.04 * (layers.length - li))).round(2)
    parts.unshift(%(<rect x="#{pad}" y="#{band_top}" width="#{w - (2 * pad)}" height="#{band_h}" rx="3" fill="#{c[:accent]}" fill-opacity="#{opacity}"/>))
    parts.unshift(%(<rect x="#{pad}" y="#{band_top}" width="3" height="#{band_h}" fill="#{c[:accent]}"/>))
    parts << label(pad + 16, band_top + (band_h / 2.0) + 4, layer[:label], c, accent: true) unless phone
    y += 6
  end
  h = y - 6 + pad
  [h + GAP, card(w, h, c) + parts.join, POP_CSS]
end

POP_CSS = <<~CSS
  .pop { opacity: 0; animation: pop 0.45s cubic-bezier(0.2, 0.8, 0.2, 1) forwards; }
  @keyframes pop { from { opacity: 0; transform: translateY(6px); } to { opacity: 1; transform: none; } }
  @media (prefers-reduced-motion: reduce) { .pop { animation: none; opacity: 1; } }
CSS

# A Simple Icons logo in its brand colour, or a monogram tile when the tool has no logo.
# Brand colours too dark for the navy sheet fall back to the ink colour.
def ink_or(hex, c)
  r, g, b = hex.scan(/../).map { |h| h.to_i(16) / 255.0 }
  (0.2126 * r) + (0.7152 * g) + (0.0722 * b) < 0.18 ? c[:ink] : "##{hex}"
end

def logo(item, x, y, size, c)
  if (brand = BRANDS[item[:icon]])
    # A one-colour mark is drawn in ink so it reads on the dark chips.
    fill = brand[:mono] ? %( fill="#{c[:ink]}") : ""
    return %(<svg x="#{x.round(1)}" y="#{y.round(1)}" width="#{size}" height="#{size}" viewBox="#{brand[:viewBox]}"#{fill}>#{brand[:body]}</svg>)
  end

  icon = ICONS[item[:icon]]
  unless icon
    return %(<rect x="#{x.round(1)}" y="#{y.round(1)}" width="#{size}" height="#{size}" rx="3" fill="none" stroke="#{c[:muted]}"/>) +
           text(x + (size / 2.0), y + (size * 0.75), item[:name][0], c, size: size * 0.7, fill: :muted, anchor: "middle", weight: 700)
  end

  colour = ink_or(icon[:hex], c)
  %(<path transform="translate(#{x.round(1)} #{y.round(1)}) scale(#{(size / 24.0).round(4)})" d="#{icon[:path]}" fill="#{colour}"/>)
end

def footer_panel(w, c, _phone)
  [40, label(w / 2.0, 24, DATA[:footer].upcase, c, anchor: "middle")]
end

# Live panels --------------------------------------------------------------

def graphql(query, variables = {})
  token = ENV["GITHUB_TOKEN"] || `gh auth token`.strip
  res = Net::HTTP.post(URI("https://api.github.com/graphql"), { query:, variables: }.to_json,
                       "Authorization" => "bearer #{token}", "Content-Type" => "application/json")
  raise "GitHub GraphQL request failed: #{res.code}" unless res.is_a?(Net::HTTPSuccess)

  body = JSON.parse(res.body, symbolize_names: true)
  raise "GitHub GraphQL errors: #{body[:errors].map { |e| e[:message] }.join("; ")}" if body[:errors]

  body[:data]
end

def upstream_pulls
  os = DATA[:open_source]
  # Only public repositories outside my own account count as upstream work. A merged PR I
  # co-authored, but did not open, is added by number since the author search misses it.
  search = "author:#{DATA[:github]} is:pr is:merged is:public -user:#{DATA[:github]}"
  owner, name = os[:coauthored][:repo].split("/")
  data = graphql(<<~GQL, { search:, owner:, name:, number: os[:coauthored][:number] })
    query($search: String!, $owner: String!, $name: String!, $number: Int!) {
      search(query: $search, type: ISSUE, first: 100) { nodes { ... on PullRequest { number mergedAt repository { nameWithOwner } } } }
      repository(owner: $owner, name: $name) { pullRequest(number: $number) { number mergedAt } }
    }
  GQL
  merged = data[:search][:nodes].map { |n| { repo: n[:repository][:nameWithOwner], number: n[:number], date: Date.parse(n[:mergedAt]) } }
  pr = data[:repository][:pullRequest]
  merged + [{ repo: os[:coauthored][:repo], number: pr[:number], date: Date.parse(pr[:mergedAt]) }]
end

def timeline_panel(pulls, w, c, phone)
  pad = phone ? 16 : 24
  # Listed repos first, in profile order; any other repo follows by its first PR date.
  order = DATA[:open_source].fetch(:lane_order, [])
  lanes = pulls.group_by { |p| p[:repo] }.sort_by { |repo, ps| [order.index(repo) || order.length, ps.map { |p| p[:date] }.min] }
  first = pulls.map { |p| p[:date] }.min
  start = Date.new(first.year, (((first.month - 1) / 3) * 3) + 1, 1)
  finish = Date.today >> 1
  label_w = phone ? 0 : 200
  ax0 = pad + label_w + 10
  ax1 = w - pad - (phone ? 76 : 60)
  xpos = ->(date) { ax0 + ((date - start).to_f / (finish - start) * (ax1 - ax0)) }
  parts = []

  y = pad + 26
  parts << text(pad, y, DATA[:open_source][:title], c, size: phone ? 20 : 26, font: :sans, weight: 700)
  y += 32

  lane_h = phone ? 46 : 40
  top = y
  lanes.each do |repo, ps|
    ly = y + (phone ? 30 : 20)
    if phone
      parts << label(pad, y + 12, repo.upcase, c)
    else
      parts << text(pad, ly + 4, repo, c, size: 12)
    end
    parts << hairline(ax0, ly, ax1, ly, c, opacity: 0.25, dash: "2 4")
    ps.sort_by { |p| p[:date] }.each do |p|
      x = xpos.(p[:date])
      mark = %(<circle cx="#{x.round(1)}" cy="#{ly}" r="6" fill="#{c[:accent]}" stroke="#{c[:surface]}" stroke-width="2"><title>#{p[:repo]} ##{p[:number]}, merged #{p[:date]}</title></circle>)
      # Marks pop in along the time axis, oldest first.
      delay = (0.3 + ((x - ax0) / (ax1 - ax0) * 1.4)).round(2)
      parts << %(<g class="dot" style="animation-delay: #{delay}s">#{mark}</g>)
    end
    parts << label(w - pad, ly + 4, "#{ps.length} MERGED", c, anchor: "end")
    y += lane_h + (phone ? 6 : 0)
  end
  y += 6
  parts << hairline(ax0, y, ax1, y, c, opacity: 0.45)
  d = start
  while d <= finish
    x = xpos.(d)
    parts << hairline(x, y, x, y + 5, c, opacity: 0.45)
    parts << label(x, y + 20, d.month == 1 ? d.year.to_s : d.strftime("%b").upcase, c, anchor: "middle") if phone ? d.month == 1 || d == start : true
    d >>= 3
  end
  y += 36
  h = y + pad
  css = <<~CSS
    .dot { transform-box: fill-box; transform-origin: center; animation: dot 0.5s cubic-bezier(0.3, 1.6, 0.5, 1) both; }
    @keyframes dot { from { transform: scale(0); } to { transform: scale(1); } }
    @media (prefers-reduced-motion: reduce) { .dot { animation: none; } }
  CSS
  [h + GAP, card(w, h, c) + parts.join, css]
end

def contribution_weeks
  graphql(<<~GQL, { login: DATA[:github] }).dig(:user, :contributionsCollection, :contributionCalendar, :weeks)
    query($login: String!) {
      user(login: $login) { contributionsCollection { contributionCalendar { weeks { contributionDays { date contributionCount } } } } }
    }
  GQL
end

def streaks(days)
  longest = run = 0
  days.each do |d|
    run = d[:contributionCount].positive? ? run + 1 : 0
    longest = [longest, run].max
  end
  # Today may have no contributions yet, so a streak that ended yesterday is still current.
  tail = days.last[:contributionCount].zero? ? days[0...-1] : days
  [longest, tail.reverse.take_while { |d| d[:contributionCount].positive? }.length]
end

# One building per day: weeks run left to right, weekdays recede into the distance.
def city_panel(weeks, w, c, phone)
  pad = phone ? 16 : 24
  days = weeks.flat_map { |wk| wk[:contributionDays] }
  shown = phone ? weeks.last(26) : weeks
  busiest = days.max_by { |d| d[:contributionCount] }
  longest, = streaks(days)
  active = days.count { |d| d[:contributionCount].positive? }
  parts = []

  tiles = [
    [thousands(days.sum { |d| d[:contributionCount] }), "CONTRIBUTIONS"],
    [busiest[:contributionCount].to_s, "BUSIEST · #{Date.parse(busiest[:date]).strftime("%-d %b").upcase}"],
    ["#{longest}d", "LONGEST STREAK"],
    ["#{active}", "ACTIVE DAYS"]
  ]
  cols = phone ? 2 : 4
  tile_w = (w - (2 * pad)) / cols.to_f
  y = pad
  tiles.each_slice(cols) do |row|
    row.each_with_index do |(value, name), i|
      x = pad + (i * tile_w)
      parts << text(x, y + 28, value, c, size: phone ? 24 : 30, font: :sans, weight: 700)
      parts << label(x, y + 48, name, c)
    end
    y += 62
  end

  step = phone ? 11.2 : 12.6
  bw = step * 0.78
  dx = step * 0.55 # each weekday row shifts right and up, giving depth
  dy = -step * 0.34
  max_h = phone ? 70 : 96
  peak = Math.sqrt(busiest[:contributionCount].clamp(1, nil))
  ground = y + max_h + (7 * -dy) + (phone ? 34 : 48)
  x0 = pad + ((w - (2 * pad) - ((shown.length * step) + (6 * dx) + bw)) / 2.0)

  # Night sky behind the skyline: twinkling stars, a crescent moon and two searchlights.
  # Positions come from a fixed-seed generator, so they stay put between daily builds.
  sky_top = y + 6
  sky_bottom = ground - (max_h * 0.55)
  rng = Random.new(20_171_022)
  (phone ? 22 : 46).times do
    sx = (pad + (rng.rand * (w - (2 * pad)))).round(1)
    sy = (sky_top + (rng.rand * (sky_bottom - sky_top))).round(1)
    r = (0.6 + (rng.rand * 0.9)).round(2)
    parts << %(<circle class="star" cx="#{sx}" cy="#{sy}" r="#{r}" fill="#{c[:ink]}" style="animation-duration: #{(2 + (rng.rand * 3)).round(2)}s; animation-delay: #{(rng.rand * -4).round(2)}s"/>)
  end
  mx = w - pad - (phone ? 26 : 44)
  my = sky_top + 14
  parts << %(<circle cx="#{mx}" cy="#{my}" r="10" fill="#{c[:window]}" fill-opacity="0.9"/><circle cx="#{mx + 5}" cy="#{my - 3}" r="9" fill="#{c[:surface]}"/>)
  city_w = (shown.length * step) + (6 * dx)
  [[0.28, 0], [0.72, -3.5]].each do |at, phase|
    bx = (x0 + (city_w * at)).round(1)
    spread = 26
    parts << %(<path class="beam" d="M#{bx - 3} #{(ground - 8).round(1)}L#{bx - spread} #{sky_top}L#{bx + spread} #{sky_top}L#{bx + 3} #{(ground - 8).round(1)}Z" fill="url(#beam)" style="animation-delay: #{phase}s"/>)
  end
  parts.unshift(%(<defs><linearGradient id="beam" x1="0" y1="1" x2="0" y2="0"><stop offset="0" stop-color="#{c[:window]}" stop-opacity="0.22"/><stop offset="1" stop-color="#{c[:window]}" stop-opacity="0"/></linearGradient></defs>))

  # Buildings grow smoothly on a loop: taller ones take a little longer, so the skyline keeps
  # climbing after the low blocks finish. The city holds, sinks gently, then rebuilds.
  # Heights fall into a few buckets, each with its own keyframes on one shared cycle.
  cycle = 20.0
  buckets = 6
  grow = lambda do |b|
    done = 1.6 + (b * 0.3)
    pct = ->(sec) { (sec / cycle * 100).round(2) }
    "@keyframes grow#{b} { 0% { transform: scaleY(0); animation-timing-function: cubic-bezier(0.22, 1, 0.36, 1); } " \
      "#{pct.(done)}%, 82% { transform: scaleY(1); animation-timing-function: cubic-bezier(0.65, 0, 0.35, 1); } 94%, 100% { transform: scaleY(0); } }"
  end
  grow_css = (1..buckets).map { grow.(it) }.join("\n")
  beacon_days = days.max_by(5) { |d| d[:contributionCount] }.map { it[:date] }
  far = x0 + (6 * dx)
  parts << %(<path d="M#{x0.round(1)} #{(ground + 4).round(1)}L#{(x0 + (shown.length * step) + 4).round(1)} #{(ground + 4).round(1)}L#{(far + (shown.length * step) + 4 + bw).round(1)} #{(ground + (6 * dy) - 2).round(1)}L#{(far - 4).round(1)} #{(ground + (6 * dy) - 2).round(1)}Z" fill="#{c[:line]}" fill-opacity="0.06"/>)
  6.downto(0) do |row|
    shown.each_with_index do |week, col|
      day = week[:contributionDays].find { |d| Date.parse(d[:date]).wday == row }
      next unless day

      n = day[:contributionCount]
      gx = x0 + (col * step) + (row * dx)
      gy = ground + (row * dy)
      ddx = dx * 0.8
      ddy = dy * 0.8
      if n.zero?
        parts << %(<path d="M#{gx.round(1)} #{gy.round(1)}h#{bw.round(1)}l#{ddx.round(1)} #{ddy.round(1)}h-#{bw.round(1)}Z" fill="#{c[:line]}" fill-opacity="0.12"/>)
        next
      end
      h = (4 + (Math.sqrt(n) / peak * (max_h - 4))).round(1)
      opacity = (0.55 + (0.45 * Math.sqrt(n) / peak)).round(2)
      # Building starts left to right, the back rows a beat after the front.
      delay = ((col * 0.03) + ((6 - row) * 0.05) + 0.2).round(3)
      bucket = ((h / max_h) * buckets).ceil.clamp(1, buckets)
      parts << %(<g class="rise" style="animation-name: grow#{bucket}; animation-delay: #{delay}s" fill-opacity="#{opacity}"><title>#{n} on #{day[:date]}</title>) +
               %(<path d="M#{(gx + bw).round(1)} #{gy.round(1)}l#{ddx.round(1)} #{ddy.round(1)}v-#{h}l-#{ddx.round(1)} #{(-ddy).round(1)}Z" fill="#{c[:side]}"/>) +
               %(<path d="M#{gx.round(1)} #{(gy - h).round(1)}h#{bw.round(1)}l#{ddx.round(1)} #{ddy.round(1)}h-#{bw.round(1)}Z" fill="#{c[:top]}"/>) +
               %(<rect x="#{gx.round(1)}" y="#{(gy - h).round(1)}" width="#{bw.round(1)}" height="#{h}" fill="#{c[:face]}"/>)
      # Lit windows on taller buildings, placed by the date so they stay put between builds.
      if h > 26
        seed = day[:date].delete("-").to_i
        (h / 9).floor.times do |k|
          next unless ((seed >> k) & 1) == 1

          # About one window in four flickers, on its own rhythm.
          flicker = ((seed >> (k + 3)) & 3).zero? ? %( class="lit" style="animation-duration: #{3 + (seed % 5)}s; animation-delay: #{-(k + (seed % 7))}s") : ""
          parts << %(<rect#{flicker} x="#{(gx + (bw * 0.3)).round(1)}" y="#{(gy - h + 6 + (k * 9)).round(1)}" width="#{(bw * 0.4).round(1)}" height="2.5" fill="#{c[:window]}" fill-opacity="0.9"/>)
        end
      end
      if beacon_days.include?(day[:date])
        parts << %(<circle class="beacon" cx="#{(gx + (bw / 2)).round(1)}" cy="#{(gy - h - 3).round(1)}" r="1.6" fill="#ff5f57"/>)
      end
      parts << "</g>"
    end
  end

  y = ground + 30
  parts << label(pad, y, "FIG. 05 · CONTRIBUTION CITY · ONE BUILDING PER DAY", c) unless phone
  parts << label(pad, y, "LAST 26 WEEKS", c) if phone
  parts << label(w - pad, y, "UPDATED #{Date.today.strftime("%-d %b %Y").upcase}", c, anchor: "end")
  h = y + pad - 6
  css = <<~CSS
    .rise { transform-box: fill-box; transform-origin: 50% 100%; transform: scaleY(0); animation-duration: #{cycle}s; animation-iteration-count: infinite; animation-fill-mode: both; }
    .beacon { animation: beacon 1.4s steps(1) infinite; }
    .star { animation-name: twinkle; animation-timing-function: ease-in-out; animation-iteration-count: infinite; animation-direction: alternate; }
    .lit { animation-name: flicker; animation-timing-function: steps(1); animation-iteration-count: infinite; }
    .beam { transform-box: fill-box; transform-origin: 50% 100%; animation: sweep 7s ease-in-out infinite alternate; }
    #{grow_css}
    @keyframes beacon { 50% { opacity: 0.15; } }
    @keyframes twinkle { from { opacity: 0.15; } to { opacity: 0.9; } }
    @keyframes flicker { 0% { opacity: 1; } 70% { opacity: 0.15; } 85% { opacity: 1; } }
    @keyframes sweep { from { transform: rotate(-22deg); } to { transform: rotate(22deg); } }
    @media (prefers-reduced-motion: reduce) { .rise, .star, .lit, .beam, .beacon { animation: none; } .rise { transform: none; } }
  CSS
  [h + GAP, card(w, h, c) + parts.join, css]
end

# Output -------------------------------------------------------------------

# Each panel is drawn inside the sheet's margins, padded at the top when it opens the sheet,
# and its height snapped to the grid so grid lines run unbroken from panel to panel.
# sides picks which edges get a margin; a panel that starts mid-grid passes grid_x.
def emit(dir, name, alt, wide: WIDE, phone: PHONE, sides: %i[left right], top: false, round: nil, grid_x: 0)
  c = THEMES.fetch("dark")
  { "" => [wide, false], "-phone" => [phone, true] }.each do |suffix, (w, is_phone)|
    m = SHEET.fetch(is_phone)
    left = sides.include?(:left) ? m : 0
    right = sides.include?(:right) ? m : 0
    pad_top = top ? m : 0
    h, body, css = yield(w - left - right, c, is_phone)
    total = ((h + pad_top).to_f / GRID).ceil * GRID
    body = %(<g transform="translate(#{left} #{pad_top})">#{body}</g>)
    File.write(File.join(dir, "#{name}#{suffix}.svg"), document(w, total, c, alt, body, css.to_s, grid_x:, round:))
  end
end

def fresh_dir(name)
  dir = File.join(ROOT, name)
  Dir.mkdir(dir) unless Dir.exist?(dir)
  Dir.children(dir).each { |f| File.delete(File.join(dir, f)) if f.end_with?(".svg") }
  dir
end

def build_live
  out = fresh_dir("live")
  pulls = upstream_pulls
  emit(out, "upstream", "#{pulls.length} pull requests merged upstream") { |w, c, p| timeline_panel(pulls, w, c, p) }
  weeks = contribution_weeks
  total = weeks.sum { |wk| wk[:contributionDays].sum { |d| d[:contributionCount] } }
  emit(out, "city", "Contribution city: one building per day of the last 12 months, #{thousands(total)} contributions in all.") { |w, c, p| city_panel(weeks, w, c, p) }
end

def build_static
  assets = fresh_dir("assets")
  d = DATA
  emit(assets, "header", "#{d[:name]}, #{d[:title]}. #{d[:intro][:fields].map { |k, v| "#{k}: #{v}" }.join(". ")}", top: true, round: :top) { |w, c, p| header_panel(w, c, p) }
  [["01", "OPEN SOURCE", "LIVE FROM GITHUB"], ["02", "AGENTIC ENGINEERING", "HARNESS + GUARDRAILS"], ["03", "WHAT I BUILD", "END TO END"], ["04", "STACK", nil], ["05", "ACTIVITY", "PUBLIC AND PRIVATE"]].each do |number, title, note|
    emit(assets, "section-#{number}", "#{number} · #{title}") { |w, c, p| section_panel(number, title, note, w, c, p) }
  end
  emit(assets, "agents", "Agentic engineering: #{d[:agents][:alt]}") { |w, c, p| agents_panel(w, c, p) }
  emit(assets, "build", "What I build, end to end: #{d[:capabilities][:layers].map { |l| "#{l[:name].capitalize}: #{l[:detail]}" }.join(". ")}. #{d[:capabilities][:dx][:name].capitalize}: #{d[:capabilities][:dx][:detail]}.") { |w, c, p| capabilities_panel(w, c, p) }
  emit(assets, "stack", d[:stack].map { |g| "#{g[:label].capitalize}: #{g[:items].map { |i| i[:name] }.join(", ")}" }.join(". ")) { |w, c, p| stack_panel(w, c, p) }
  emit(assets, "footer", d[:footer], round: :bottom) { |w, c, p| footer_panel(w, c, p) }
end

def picture(name, alt, href: nil, width: "100%", branch: "main", dir: "assets/")
  url = ->(variant) { "https://github.com/#{REPO}/raw/#{branch}/#{dir}#{name}#{variant}.svg" }
  pic = %(<picture><source media="(max-width: 600px)" srcset="#{url["-phone"]}"><img src="#{url[""]}" width="#{width}" align="top" alt="#{esc(alt)}"></picture>)
  href ? %(<a href="#{href}">#{pic}</a>) : pic
end

def build_readme
  d = DATA
  lines = []
  lines << picture("header", "#{d[:name]}, #{d[:title]}. #{d[:intro][:fields].map { |k, v| "#{k}: #{v}" }.join(". ")}")
  lines << picture("section-01", "01 · Open source")
  lines << picture("upstream", "Timeline of pull requests merged upstream", href: d[:open_source][:url], branch: "output", dir: "")
  lines << picture("section-02", "02 · Agentic engineering")
  lines << picture("agents", "Agentic engineering: #{d[:agents][:alt]}")
  lines << picture("section-03", "03 · What I build")
  lines << picture("build", "What I build, end to end: #{d[:capabilities][:layers].map { |l| l[:name].capitalize }.join(", ")}, with developer experience across every layer")
  lines << picture("section-04", "04 · Stack")
  lines << picture("stack", d[:stack].flat_map { |g| g[:items].map { |i| i[:name] } }.join(", "))
  lines << picture("section-05", "05 · Activity")
  lines << picture("city", "Contribution city: one building per day of the last 12 months", branch: "output", dir: "")
  lines << picture("footer", d[:footer])

  File.write(File.join(ROOT, "README.md"), <<~MD)
    <!-- Code generated by `mise run readme` from data/profile.json; DO NOT EDIT. -->
    <p align="center">
    #{lines.join("\n")}
    </p>
  MD
end

if ARGV.first == "live"
  build_live
else
  build_static
  build_live
  build_readme
end
