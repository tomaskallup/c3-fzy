module c3_fzy;

import std::io;
import std::collections::list;

import terminal_interface::ti;

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
  TerminalInterface terminal_interface;
  bool cancelled;
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

fn void! render(State state)
{
  // Clear the screen
  state.terminal_interface.clear()!;

  String query = state.query.str_view();

  // Set color for prompt
	state.terminal_interface.write(ti::@escape_sequence("[0m"))!;

  // Render prompt
  String prompt = string::tformat(">> %s", query);
  state.terminal_interface.set_line(1, prompt)!;

  // @TODO: Handle window size
  usz mark = allocator::temp().mark();
  foreach (i, option: state.filtered_options) {
    DString option_colored;
    option_colored.temp_init();

    usz last_index = 0;
    bool continuous = false;

    if (i == state.selected_index) {
      option_colored.append_chars(ti::@escape_sequence("[48;5;245m"));
    } else {
      option_colored.append_chars(ti::@escape_sequence("[49m"));
    }
    if (!option.match_indexes.len()) {
      option_colored.append_chars(ti::@escape_sequence("[39m"));
      option_colored.append_chars(option.value);
    } else {
      // @TODO: Maybe use for(usz mi = 0; mi < option.match_indexes.len(); mi++) with a while cycle inside to simplify?
      foreach (match_index: option.match_indexes) {
        if (match_index - last_index > 1 || (match_index != last_index && !continuous)) {
          option_colored.append_chars(ti::@escape_sequence("[39m"));
          String to_append;
          if (!continuous) {
            to_append = option.value[last_index..match_index-1];
          } else {
            to_append = option.value[last_index+1..match_index-1];
          }
          option_colored.append_chars(to_append);
          continuous = false;
        }

        if (!continuous) {
          option_colored.append_chars(ti::@escape_sequence("[38;5;40m"));
          continuous = true;
        }

        option_colored.append_char(option.value[match_index]);

        last_index = match_index;
      }

      if (last_index < option.value.len) 
      {
        option_colored.append_chars(ti::@escape_sequence("[39m"));
        option_colored.append_chars(option.value[last_index+1..]);
      }
    }

    state.terminal_interface.set_line(2 + i, option_colored.str_view())!;
  }
  allocator::temp().reset(mark);

  state.terminal_interface.write(ti::@escape_sequence("[6 q"))!;
  state.terminal_interface.set_cursor_pos(1, PROMPT.len + 1 + state.cursor)!;

  // Clear styles after rendering
	state.terminal_interface.write(ti::@escape_sequence("[0m"))!;
  state.terminal_interface.flush()!;
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
  if (catch excuse = state.terminal_interface.close()) {
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

  state.terminal_interface.input_file = &&file::open("/dev/tty", "r")!!;
  state.terminal_interface.output_file = &&file::open("/dev/tty", "w")!!;
  state.terminal_interface.init();
  if (catch excuse = state.terminal_interface.start()) {
    error.append_chars(string::tformat("%s", excuse));
    return 1;
  }

  bool should_loop = true;
  while (should_loop) {
    if (catch excuse = render(state)) {
      error.append_chars(string::tformat("Render failed: %s", excuse));
      should_loop = false;
      state.cancelled = true;
      return 1;
    }

    char[3] buf;
    usz len;
    usz wanted_len = 1;
    do {
      char! ch = state.terminal_interface.input_file.read_byte();
      if (catch excuse = ch){
        error.append_chars(string::tformat("Read failed: %s", excuse));
        should_loop = false;
        state.cancelled = true;
        return 1;
      }
      buf[len++] = ch;

      // Handle multibytes
      if (len == 1 && buf[0] == 27) wanted_len = 3;
    } while(len < wanted_len);

    String input = (String)buf[0..len-1];
    usz old_query_len = state.query.len();

    /* io::print(len);
    io::print(input);
    io::printn((char[])input); */

    switch (input) {
      case String{ti::@ctrl_key('c')}:
        should_loop = false;
        state.cancelled = true;
        return 1;
      // Backspace
      case String{127}:
        if (old_query_len > 0 && state.cursor) {
          state.query.delete(state.cursor - 1);
          state.cursor--;
        }
      // Enter key
      case String{10}:
        should_loop = false;
      // Left arrow key
      case String{27,91,68}:
        nextcase;
      case String{ti::@ctrl_key('h')}:
        if (state.cursor) state.cursor--;
      // Right arrow key
      case String{27,91,67}:
        nextcase;
      case String{ti::@ctrl_key('l')}:
        if (state.cursor < old_query_len) state.cursor++;
      // Up arrow key
      case String{27,91,65}:
        nextcase;
      case String{27,91,90}:
        nextcase;
      case String{ti::@ctrl_key('p')}:
        if (state.filtered_options.len()) {
          if (state.selected_index) state.selected_index--;
        }
      // Down arrow key
      case String{27,91,66}:
        nextcase;
      case String{9}:
        nextcase;
      case String{ti::@ctrl_key('n')}:
        if (state.selected_index < state.filtered_options.len() - 1) {
          state.selected_index++;
        }
      default:
        state.query.insert_chars_at(state.cursor, input);
        state.cursor++;
    }

    usz new_query_len = state.query.len();

    if (old_query_len != new_query_len) {
      filter_options(&state);
    }
  }

	return 0;
}
