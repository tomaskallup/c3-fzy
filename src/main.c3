module c3_fzy;

import std::io;
import std::collections::list;
import std::math;

import terminal_interface;

const PROMPT=">> ";

KeyMap keymap;

struct FilteredOption {
  String value;
  List{usz} match_indexes;
}

fn void FilteredOption.free(&self)
{
  self.match_indexes.free();

  mem::free(self);
}

alias FilteredOptions = List{FilteredOption*};

struct State {
  List{String} options;
  FilteredOptions filtered_options;
  DString query;
  usz cursor;
  usz selected_index;
  bool cancelled;
  Winsize winsize;
}

State state;

fn void filter_options()
{
  state.selected_index = 0;
  String query = state.query.str_view();
  String lower_query = query.to_lower_copy(tmem);
  foreach(filtered_option: state.filtered_options) filtered_option.free();
  state.filtered_options.clear();

  // Very, very basic fuzzy filter
  foreach(option: state.options) {
    if (!query.len) {
      FilteredOption* filtered_option = mem::new(FilteredOption, {
        .value = option,
      });
      state.filtered_options.push(filtered_option);

      continue;
    }

    // String lower_option = option.temp_ascii_to_lower();

    usz option_index = 0;
    List{usz} matching_indexes;
    matching_indexes.init(mem);
    for (usz i = 0; i < query.len; i++) {
      char needle = query[i];
      // char lower_needle = lower_query[i];
      while (option_index < option.len) {
        if (/* lower_ */option[option_index] == /* lower_ */needle) {
          matching_indexes.push(option_index++);
          break;
        }
        option_index++;
      }
    }

    if (matching_indexes.size == query.len) {
      FilteredOption* filtered_option = mem::new(FilteredOption, {
        .value = option,
      });
      filtered_option.match_indexes = matching_indexes;
      state.filtered_options.push(filtered_option);
    } else {
      matching_indexes.free();
    }
  }
}

fn void? update_cursor()
{
  ti::set_cursor_pos(1, PROMPT.len + 1 + state.cursor)!;
  ti::flush()!;
}

fn void? render()
{
  // Clear the screen
  ti::clear()!;

  String query = state.query.str_view();

  Winsize winsize = state.winsize;
  usz free_lines = (usz)winsize.ws_row - 3;

  @pool() {
    // Render prompt
    TermString prompt;
    prompt.tinit();
    prompt.reset_style();
    prompt.append(PROMPT);
    prompt.color_256(40).append_style(Style.BOLD);
    prompt.append(query);
    prompt.reset_style();
    ti::set_line(1, prompt.str_view())!;

    TermString rendered_option;
    rendered_option.tinit();
    usz filtered_count = state.filtered_options.len();
    if (filtered_count) {
      FilteredOption*[] options_to_render = state.filtered_options.array_view()[state.selected_index:math::min(free_lines,filtered_count - state.selected_index)];

      foreach (i, option: options_to_render) {
        rendered_option.clear();
        usz last_index = 0;
        bool continuous = false;

        if (i == 0) {
          rendered_option.color_256(245, true);
        } else {
          rendered_option.color_simple(SimpleColor.BG_DEFAULT);
        }

        // @TODO: Handle limited space horizontally
        if (!option.match_indexes.len()) {
          rendered_option.color_simple(SimpleColor.DEFAULT);
          rendered_option.append_chars(option.value);
        } else {
          for (usz mi = 0; mi < option.match_indexes.len(); mi++) {
            usz match_index = option.match_indexes[mi];

            if (match_index > 0) {
              rendered_option.color_simple(SimpleColor.DEFAULT);
              usz start = mi == 0 ? last_index : last_index + 1;
              rendered_option.append_chars(option.value[start..match_index-1]);
            }

            // Skip over continuous indexes
            while ((mi + 1) < option.match_indexes.len() && option.match_indexes[mi+1] - option.match_indexes[mi] == 1) mi++;

            usz end_index = option.match_indexes[mi];

            rendered_option.color_256(40);
            rendered_option.append_chars(option.value[match_index..end_index]);

            last_index = end_index;
          }

          if (last_index < option.value.len) 
          {
            rendered_option.color_simple(SimpleColor.DEFAULT);
            rendered_option.append_chars(option.value[last_index+1..]);
          }
        }

        ti::set_line(2 + i, rendered_option.str_view())!;
      }
    }
  };

  // Clear styles after rendering & flush
  ti::reset_style(true)!;

  update_cursor()!;
}

DString error;

fn void cleanup()
{
  String selected;
  if (!state.cancelled && state.filtered_options.len()) {
    selected = state.filtered_options[state.selected_index].value;
  }

  foreach(filtered_option: state.filtered_options) filtered_option.free();
  state.filtered_options.free();
  if (catch excuse = ti::close()) {
    error.append_chars(string::tformat("%s", excuse));
  }

  if (error && error.len() > 0) {
    io::eprintn("Error:");
    io::eprintn(error);
  } else {
    if (selected) io::printn(selected);
  }
}

fn void on_resize(Winsize winsize)
{
  state.winsize = winsize;

  if (catch excuse = render()) {
    error.append_chars(string::tformat("Render failed: %s", excuse));
    state.cancelled = true;
    ti::stop();
  }
}

fn void handle_key(Key key)
{
  bool should_render;

  usz old_query_len = state.query.len();
  
  switch (key) {
    // Backspace
    case key::BSPC:
      if (old_query_len > 0 && state.cursor) {
        state.query.delete(state.cursor - 1);
        state.cursor--;
        should_render = true;
      }
    // Enter key
    case key::ENTER:
      ti::stop();
    case key::ctrl_key('c'):
      state.cancelled = true;
      ti::stop();

    // Left arrow key
    case key::LEFT:
      nextcase;
    case key::ctrl_key('h'):
      if (state.cursor) {
        state.cursor--;
        update_cursor()!!;
      }
    // Right arrow key
    case key::RIGHT:
      nextcase;
    case key::ctrl_key('l'):
      if (state.cursor < old_query_len) {
        state.cursor++;
        update_cursor()!!;
      }
    // Up arrow key
    case key::UP:
      nextcase;
    case key::ctrl_key('p'):
      if (state.filtered_options.len()) {
        if (state.selected_index) {
          state.selected_index--;
          should_render = true;
        }
      }
    // Down arrow key
    case key::DOWN:
      nextcase;
    case key::ctrl_key('n'):
      if (state.selected_index < state.filtered_options.len() - 1) {
        state.selected_index++;
        should_render = true;
      }
    default:
      if (key[1] == 0) {
        state.query.insert_char_at(state.cursor, key[0]);
        state.cursor++;
      }
  }

  if (old_query_len != state.query.len()) {
    filter_options();
    should_render = true;
  }

  if (should_render) {
    if (catch excuse = render()) {
      error.append_chars(string::tformat("Render failed: %s", excuse));
      state.cancelled = true;
      ti::stop();
    }
  }
}

fn int main(String[] args)
{
  state.options.tinit();
  state.query.tinit();
  error.tinit();
  defer cleanup();

  while (true) {
    String? line = io::treadline();
    if (catch excuse = line) {
      if (excuse == io::EOF) break;
      io::eprintfn("Error reading stdin: %s", excuse);
      return 1;
    }

    state.options.push(line);
  }

  filter_options();

  keymap.tinit();
  keymap.default_handler = &handle_key;

  ti::set_keymap(keymap);

  ti::init(null, &&file::open("/dev/tty", "r"), &&file::open("/dev/tty", "w"))!!;

  state.winsize = ti::get_winsize();

  ti::start(&render)!!;

  return 0;
}
