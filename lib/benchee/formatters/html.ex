defmodule Benchee.Formatters.HTML do
  use Benchee.Formatter

  require EEx
  alias Benchee.{Suite, Statistics, Benchmark.Scenario, Configuration}
  alias Benchee.Conversion
  alias Benchee.Conversion.{Duration, Count, DeviationPercent}
  alias Benchee.Utility.FileCreation

  # Major pages
  EEx.function_from_file :defp, :comparison,
                         "priv/templates/comparison.html.eex",
                         [:input_name, :suite, :units, :suite_json, :inline_assets]
  EEx.function_from_file :defp, :job_detail,
                         "priv/templates/job_detail.html.eex",
                         [:input_name, :job_name, :job_statistics, :system,
                          :units, :job_json, :inline_assets]
  EEx.function_from_file :defp, :index,
                         "priv/templates/index.html.eex",
                         [:names_to_paths, :system, :inline_assets]

  # Partials
  EEx.function_from_file :defp, :head,
                         "priv/templates/partials/head.html.eex",
                         [:inline_assets]
  EEx.function_from_file :defp, :header,
                         "priv/templates/partials/header.html.eex",
                         [:input_name]
  EEx.function_from_file :defp, :js_includes,
                         "priv/templates/partials/js_includes.html.eex",
                         [:inline_assets]
  EEx.function_from_file :defp, :version_note,
                         "priv/templates/partials/version_note.html.eex",
                         []
  EEx.function_from_file :defp, :input_label,
                         "priv/templates/partials/input_label.html.eex",
                         [:input_name]
  EEx.function_from_file :defp, :data_table,
                         "priv/templates/partials/data_table.html.eex",
                         [:statistics, :units, :options]
  EEx.function_from_file :defp, :system_info,
                         "priv/templates/partials/system_info.html.eex",
                         [:system, :options]
  EEx.function_from_file :defp, :footer,
                         "priv/templates/partials/footer.html.eex",
                         [:dependencies]

  # Small wrappers to have default arguments
  defp render_data_table(statistics, units, options \\ []) do
    data_table statistics, units, options
  end

  defp render_system_info(system, options \\ [visible: false]) do
    system_info(system, options)
  end

  defp render_footer do
    footer(%{
      benchee: Application.spec(:benchee, :vsn),
      benchee_html: Application.spec(:benchee_html, :vsn)
    })
  end

  @moduledoc """
  Functionality for converting Benchee benchmarking results to an HTML page
  with plotly.js generated graphs and friends.

  ## Examples

      list = Enum.to_list(1..10_000)
      map_fun = fn(i) -> [i, i * i] end

      Benchee.run(%{
        "flat_map"    => fn -> Enum.flat_map(list, map_fun) end,
        "map.flatten" => fn -> list |> Enum.map(map_fun) |> List.flatten end
      },
        formatters: [
          &Benchee.Formatters.HTML.output/1,
          &Benchee.Formatters.Console.output/1
        ],
        formatter_options: [html: [file: "samples_output/flat_map.html"]],
      )

  """

  @doc """
  Transforms the statistical results from benchmarking to html to be written
  somewhere, such as a file through `IO.write/2`.

  Returns a map from file name/path to file content along with formatter options.
  """
  @spec format(Suite.t) :: {%{Suite.key => String.t}, map}
  def format(suite) do
    suite
    |> default_configuration
    |> do_format
  end

  @default_filename "benchmarks/output/results.html"
  @default_auto_open true
  @default_inline_assets false
  defp default_configuration(suite) do
    opts = suite.configuration.formatter_options
           |> Map.get(:html, %{})
           |> Map.put_new(:file, @default_filename)
           |> Map.put_new(:auto_open, @default_auto_open)
           |> Map.put_new(:inline_assets, @default_inline_assets)
    updated_configuration = %Configuration{suite.configuration | formatter_options: %{html: opts}}
    load_specs_for_versions()
    %Suite{suite | configuration: updated_configuration}
  end

  defp load_specs_for_versions do
    _ = Application.load :benchee
    _ = Application.load :benchee_html
  end

  defp do_format(%Suite{scenarios: scenarios, system: system,
               configuration: %{
                 formatter_options: %{html: options = %{file: filename, inline_assets: inline_assets}},
                 unit_scaling: unit_scaling
               }}) do
    data = scenarios
           |> Enum.group_by(fn(scenario) -> scenario.input_name end)
           |> Enum.map(fn(tagged_scenarios) ->
                reports_for_input(tagged_scenarios, system, filename, unit_scaling, inline_assets)
              end)
           |> add_index(filename, system, inline_assets)
           |> List.flatten
           |> Map.new

    {data, options}
  end

  @doc """
  Uses output of `Benchee.Formatters.HTML.format/1` to transform the statistics
  output to HTML with JS, but also already writes it to files defined in the
  initial configuration under `formatter_options: [html: [file:
  "benchmark_out/my.html"]]`.

  Generates the following files:

  * index file (exactly like `file` is named)
  * a comparison of all the benchmarked jobs (one per benchmarked input)
  * for each job a detail page with more detailed run time graphs for that
    particular job (one per benchmark input)
  """
  @spec write({%{Suite.key => String.t}, map}) :: :ok
  def write({data, %{file: filename, auto_open: auto_open?, inline_assets: inline_assets?}}) do
    prepare_folder_structure(filename, inline_assets?)

    FileCreation.each(data, filename)

    if auto_open?, do: open_report(filename)

    :ok
  end

  defp prepare_folder_structure(filename, inline_assets?) do
    base_directory = create_base_directory(filename)

    unless inline_assets?, do: copy_asset_files(base_directory)

    base_directory
  end

  defp create_base_directory(filename) do
    base_directory = Path.dirname filename
    File.mkdir_p! base_directory
    base_directory
  end

  @asset_directory "assets"
  defp copy_asset_files(base_directory) do
    asset_target_directory = Path.join(base_directory, @asset_directory)
    asset_source_directory = Application.app_dir(:benchee_html, "priv/assets/")
    File.cp_r! asset_source_directory, asset_target_directory
  end

  defp reports_for_input({input_name, scenarios}, system, filename, unit_scaling, inline_assets) do
    units = Conversion.units(scenarios, unit_scaling)
    job_reports = job_reports(input_name, scenarios, system, units, inline_assets)
    comparison  = comparison_report(input_name, scenarios, system, filename, units, inline_assets)
    [comparison | job_reports]
  end

  defp job_reports(input_name, scenarios, system, units, inline_assets) do
    # extract some of me to benchee_json pretty please?
    Enum.map(scenarios, fn(scenario) ->
      job_json = json_encode!(%{
        statistics: scenario.run_time_statistics,
        run_times: scenario.run_times
      })
      {
        [input_name, scenario.name],
        job_detail(input_name, scenario.name, scenario.run_time_statistics, system, units, job_json, inline_assets)
      }
    end)
  end

  defp comparison_report(input_name, scenarios, system, filename, units, inline_assets) do
    input_json = format_scenarios_for_input(scenarios)

    sorted_statistics = scenarios
                        |> Statistics.sort()
                        |> Enum.map(fn(scenario) -> {scenario.name, %{run_time_statistics: scenario.run_time_statistics}} end)
                        |> Map.new

    input_run_times = scenarios
                      |> Enum.map(fn(scenario) -> {scenario.name, scenario.run_times} end)
                      |> Map.new
    input_suite = %{
      statistics: sorted_statistics,
      run_times:  input_run_times,
      system:     system,
      job_count:  length(scenarios),
      filename:   filename
    }

    {[input_name, "comparison"], comparison(input_name, input_suite, units, input_json, inline_assets)}
  end

  defp add_index(grouped_main_contents, filename, system, inline_assets) do
    index_structure = inputs_to_paths(grouped_main_contents, filename)
    index_entry = {[], index(index_structure, system, inline_assets)}
    [index_entry | grouped_main_contents]
  end

  defp inputs_to_paths(grouped_main_contents, filename) do
    grouped_main_contents
    |> Enum.map(fn(reports) -> input_to_paths(reports, filename) end)
    |> Map.new
  end

  defp input_to_paths(input_reports, filename) do
    [{[input_name | _], _} | _] = input_reports

    paths = Enum.map input_reports, fn({tags, _content}) ->
      relative_file_path(filename, tags)
    end
    {input_name, paths}
  end

  defp relative_file_path(filename, tags) do
    filename
    |> Path.basename
    |> FileCreation.interleave(tags)
  end

  defp format_duration(duration, unit) do
    Duration.format({Duration.scale(duration, unit), unit})
  end

  defp format_count(count, unit) do
    Count.format({Count.scale(count, unit), unit})
  end

  defp format_percent(deviation_percent) do
    DeviationPercent.format deviation_percent
  end

  @no_input Benchee.Benchmark.no_input()
  defp inputs_supplied?(@no_input), do: false
  defp inputs_supplied?(_), do: true

  defp input_headline(input_name) do
    if inputs_supplied?(input_name) do
      " (#{input_name})"
    else
      ""
    end
  end

  @job_count_class "job-count-"
  # there seems to be no way to set a maximum bar width other than through chart
  # allowed width... or I can't find it.
  defp max_width_class(job_count) when job_count < 7 do
    "#{@job_count_class}#{job_count}"
  end
  defp max_width_class(_job_count), do: ""

  defp open_report(filename) do
    browser = get_browser()
    {_, exit_code} = System.cmd(browser, [filename])
    unless exit_code > 0, do: IO.puts "Opened report using #{browser}"
  end

  defp get_browser do
    case :os.type() do
      {:unix, :darwin} -> "open"
      {:unix, _} -> "xdg-open"
      {:win32, _} -> "explorer"
    end
  end

  ## Copied from benchee_json
  defp format_scenarios_for_input(scenarios) do
    %{}
    |> add_statistics(scenarios)
    |> add_sort_order(scenarios)
    |> add_run_times(scenarios)
    |> json_encode!()
  end

  defp add_statistics(output, scenarios) do
    statistics = scenarios
                 |> Enum.map(fn(scenario) ->
                      {scenario.name, scenario.run_time_statistics}
                    end)
                 |> Map.new
    Map.put(output, "statistics", statistics)
  end

  # Sort order as determined by `Benchee.Statistics.sort`
  defp add_sort_order(output, scenarios) do
    sort_order = scenarios
                 |> Benchee.Statistics.sort
                 |> Enum.map(fn(%Scenario{name: name}) -> name end)
    Map.put(output, "sort_order", sort_order)
  end

  defp add_run_times(output, scenarios) do
    run_times = scenarios
                |> Enum.map(fn(scenario) ->
                     {scenario.name, scenario.run_times}
                   end)
                |> Map.new
    Map.put(output, "run_times", run_times)
  end

  # Use the jason lib without depending on it - this assumes it will be used
  # as a dependency in the jason project itself
  defp json_encode!(data) do
    json = Jason
    json.encode!(data)
  end
end
