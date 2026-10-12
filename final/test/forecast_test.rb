require_relative "test_helper"

# The forecast tool (Layer 11). Geocoding and the HTTP call are stubbed so
# the suite stays offline; the live lookup is opt-in via LIVE_TESTS=1.
class ForecastTest < Minitest::Test
  DENVER = { lat: 39.74, lon: -104.98, name: "Denver", country: "United States" }.freeze

  # Replaces receiver.name with impl for the duration of the block — like
  # stubbing, but impl can inspect its arguments or raise.
  def replacing(receiver, name, impl)
    original = receiver.method(name)
    receiver.define_singleton_method(name, &impl)
    yield
  ensure
    receiver.define_singleton_method(name, original)
  end

  def response(klass, code, body = "")
    resp = klass.new("1.1", code, "")
    resp.define_singleton_method(:body) { body }
    resp
  end

  def test_schema_shape
    schema = Tools::Forecast::SCHEMA
    assert_equal "get_forecast", schema[:name]
    assert_equal ["city"], schema[:input_schema][:required]
    assert_equal "integer", schema[:input_schema][:properties][:days][:type]
  end

  def test_returns_the_raw_json_body_and_asks_for_hourly_imperial_data
    body = '{"hourly":{"time":["2026-10-12T00:00"],"temperature_2m":[52.1]}}'
    requested = nil
    ok = response(Net::HTTPOK, "200", body)
    fetch = ->(uri) { requested = uri; ok }

    result = stubbing(Tools::Weather, :geocode, DENVER) do
      replacing(Net::HTTP, :get_response, fetch) { Tools::Forecast.call(city: "Denver") }
    end

    assert_equal body, result
    query = URI.decode_www_form(requested.query).to_h
    assert_equal "temperature_2m,precipitation_probability,wind_speed_10m,weather_code", query["hourly"]
    assert_equal "fahrenheit", query["temperature_unit"]
    assert_equal "mph", query["wind_speed_unit"]
    assert_equal "7", query["forecast_days"] # the default
  end

  def test_the_body_comes_back_as_utf8_not_binary
    # What Net::HTTP really hands back: the right bytes, tagged BINARY.
    body = '{"hourly_units":{"temperature_2m":"°F"}}'.b
    ok = response(Net::HTTPOK, "200", body)

    result = stubbing(Tools::Weather, :geocode, DENVER) do
      stubbing(Net::HTTP, :get_response, ok) { Tools::Forecast.call(city: "Denver") }
    end

    assert_equal Encoding::UTF_8, result.encoding
    assert result.valid_encoding?
    assert_includes JSON.generate({ result: result }), "°F"
  end

  def test_days_is_passed_through
    requested = nil
    ok = response(Net::HTTPOK, "200", "{}")
    fetch = ->(uri) { requested = uri; ok }

    stubbing(Tools::Weather, :geocode, DENVER) do
      replacing(Net::HTTP, :get_response, fetch) { Tools::Forecast.call(city: "Denver", days: 3) }
    end

    assert_equal "3", URI.decode_www_form(requested.query).to_h["forecast_days"]
  end

  def test_unknown_city
    stubbing(Tools::Weather, :geocode, nil) do
      assert_equal "Couldn't find a location matching 'Atlantis'.",
                   Tools::Forecast.call(city: "Atlantis")
    end
  end

  def test_api_error_status
    result = stubbing(Tools::Weather, :geocode, DENVER) do
      stubbing(Net::HTTP, :get_response, response(Net::HTTPBadRequest, "400")) do
        Tools::Forecast.call(city: "Denver", days: 99)
      end
    end

    assert_equal "Forecast API returned status 400.", result
  end

  def test_network_failure_becomes_a_string
    result = replacing(Tools::Weather, :geocode, ->(_city) { raise SocketError, "getaddrinfo failed" }) do
      Tools::Forecast.call(city: "Denver")
    end

    assert_equal "Error fetching forecast: getaddrinfo failed", result
  end

  def test_live_lookup
    skip "set LIVE_TESTS=1 to run the live Open-Meteo lookup" unless ENV["LIVE_TESTS"]

    result = Tools::Forecast.call(city: "Tokyo", days: 1)
    assert_includes JSON.parse(result).fetch("hourly").keys, "temperature_2m"
  end
end
