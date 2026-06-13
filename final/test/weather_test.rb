require_relative "test_helper"

# The weather tool. The schema and code-table checks are offline; the live
# Open-Meteo lookup is opt-in via LIVE_TESTS=1 so the default run stays fast
# and network-free.
class WeatherTest < Minitest::Test
  def test_schema_shape
    schema = Tools::Weather::SCHEMA
    assert_equal "get_weather", schema[:name]
    assert_includes schema[:input_schema][:required], "city"
  end

  def test_wmo_code_lookup
    assert_equal "clear sky", Tools::Weather::WMO_CODES[0]
    assert_equal "overcast", Tools::Weather::WMO_CODES[3]
  end

  def test_call_unpacks_city_and_handles_not_found
    # Stub geocode so no network call happens; nil means "no match".
    stubbing(Tools::Weather, :geocode, nil) do
      assert_equal "Couldn't find a location matching 'Atlantis'.",
                   Tools::Weather.call(city: "Atlantis")
    end
  end

  def test_live_lookup
    skip "set LIVE_TESTS=1 to run the live Open-Meteo lookup" unless ENV["LIVE_TESTS"]

    result = Tools::Weather.call(city: "Tokyo")
    assert_kind_of String, result
    assert_includes result, "Tokyo"
  end
end
