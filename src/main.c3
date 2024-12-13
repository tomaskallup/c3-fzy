module c3_fzy;

import std::io;
import std::collections::list;
import std::math;

import terminal_interface;

const PROMPT=">> ";

struct FilteredOption {
  String value;
  List(<usz>) match_indexes;
}

fn void FilteredOption.free(&self)
{
  self.match_indexes.free();

  mem::free(self);
}

def FilteredOptions = List(<FilteredOption*>);

struct State {
  List(<String>) options;
  FilteredOptions filtered_options;
  DString query;
  usz cursor;
  usz selected_index;
  bool cancelled;
  Winsize winsize;
}

fn void filter_options(State* state)
{
  state.selected_index = 0;
  String query = state.query.str_view();
  String lower_query = query.temp_ascii_to_lower();
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
    List(<usz>) matching_indexes;
    matching_indexes.new_init();
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

fn void! update_cursor(State state)
{
  // Set cursor style & position
  // ti::write(ti::@escape_sequence("[6 q"))!;
  ti::set_cursor_pos(1, PROMPT.len + 1 + state.cursor)!;
  ti::flush()!;
}

fn void! render(State state)
{
  // Clear the screen
  ti::clear()!;

  String query = state.query.str_view();

  Winsize winsize = state.winsize;
  usz free_lines = (usz)winsize.ws_row - 3;

  // Render prompt
  TermString prompt;
  prompt.temp_init();
  prompt.reset_style();
  prompt.append(PROMPT);
  prompt.color_256(40).style(Style.BOLD);
  prompt.append(query);
  prompt.style(Style.RESET_BOLD);
  ti::set_line(1, prompt.str_view())!;

  usz mark = allocator::temp().mark();
  TermString rendered_option;
  rendered_option.temp_init();
  usz filtered_count = state.filtered_options.len();
  if (filtered_count) {
    FilteredOption*[] options_to_render = state.filtered_options.array_view()[state.selected_index:math::min(free_lines,filtered_count)];

    foreach (i, option: options_to_render) {
      rendered_option.clear();
      usz last_index = 0;
      bool continuous = false;

      if (i == 0) {
        rendered_option.color_256(245, true);
      } else {
        rendered_option.color_simple(SimpleColor.BG_DEFAULT);
      }

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
  allocator::temp().reset(mark);

  TermString winsize_str;
  winsize_str.temp_init();
  winsize_str.reset_style();
  winsize_str.color_simple(SimpleColor.BLUE);
  winsize_str.appendf("Row: %d, col: %d, free: %d", winsize.ws_row, winsize.ws_col, free_lines);
  ti::set_line((usz)winsize.ws_row-1, winsize_str.str_view())!;

  // Clear styles after rendering & flush
	ti::reset_style(true)!;
}

DString error;

fn void cleanup(State* state)
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

fn int main(String[] args)
{
  State state;
  usz mark = allocator::temp().mark();
  state.options.temp_init();
  state.query.temp_init();
  error.temp_init();
  defer allocator::temp().reset(mark);
  defer cleanup(&state);

  while (true) {
    String! line = io::treadline();
    if (catch excuse = line) {
      if (excuse == IoError.EOF) break;
      io::eprintfn("Error reading stdin: %s", excuse);
      return 1;
    }

    state.options.push(line);
  }

  filter_options(&state);

  ti::init(&&file::open("/dev/tty", "r"), &&file::open("/dev/tty", "w"))!!;
  if (catch excuse = ti::start()) {
    error.append_chars(string::tformat("%s", excuse));
    return 1;
  }

  state.winsize = ti::get_winsize();

  bool should_render = true;
  while (ti::is_running()) {
    if (should_render) {
      if (catch excuse = render(state)) {
        error.append_chars(string::tformat("Render failed: %s", excuse));
        state.cancelled = true;
        return 1;
      }

      update_cursor(state)!!;
      should_render = false;
    }

    if (try event = ti::get_event()) {
      if (event.type == EventType.WIN_RESIZE) {
        state.winsize = event.new_size;
        should_render = true;
      } else if (event.type == EventType.INPUT) {
        String input = event.input;
        usz old_query_len = state.query.len();

        switch ((char[])input) {
          case {ti::@ctrl_key('c')}:
            ti::stop();
            state.cancelled = true;
            return 1;
            // Backspace
          case {127}:
            if (old_query_len > 0 && state.cursor) {
              state.query.delete(state.cursor - 1);
              state.cursor--;
            }
            // Enter key
          case {13}:
            ti::stop();
            // Left arrow key
          case {27,91,68}:
            nextcase;
          case {ti::@ctrl_key('h')}:
            if (state.cursor) {
              state.cursor--;
              update_cursor(state)!!;
            }
            // Right arrow key
          case {27,91,67}:
            nextcase;
          case {ti::@ctrl_key('l')}:
            if (state.cursor < old_query_len) {
              state.cursor++;
              update_cursor(state)!!;
            }
            // Up arrow key
          case {27,91,65}:
            nextcase;
          case {27,91,90}:
            nextcase;
          case {ti::@ctrl_key('p')}:
            if (state.filtered_options.len()) {
              if (state.selected_index) {
                state.selected_index--;
                should_render = true;
              }
            }
            // Down arrow key
          case {27,91,66}:
            nextcase;
          case {9}:
            nextcase;
          case {ti::@ctrl_key('n')}:
            if (state.selected_index < state.filtered_options.len() - 1) {
              state.selected_index++;
              should_render = true;
            }
          default:
            if (input != "") {
              state.query.insert_chars_at(state.cursor, input);
              state.cursor++;
            }
        }

        usz new_query_len = state.query.len();

        if (old_query_len != new_query_len) {
          filter_options(&state);
          should_render = true;
        }

      }
    }
  }

	return 0;
}
