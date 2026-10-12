require "net/http"
require "uri"
require_relative "weather"

module Tools
  module Forecast
    SCHEMA = {
      name: "get_forecast",
      description: "Get the hourly forecast for a given city: temperature, " \
                   "precipitation probability, wind speed, and WMO weather " \
                   "code for every hour. Returns raw Open-Meteo JSON.",
      input_schema: {
        type: "object",
        properties: {
          city: {
            type: "string",
            description: "The name of the city to get the forecast for."
          },
          days: {
            type: "integer",
            description: "How many days to forecast (1-16). Defaults to 7."
          }
        },
        required: ["city"]
      }
    }.freeze

    module_function

    def call(input)
      get_forecast(input[:city], input.fetch(:days, 7))
    end

    # Deliberately verbose: the raw hourly JSON is kilobytes per day. With
    # SUBAGENTS=1 only the helper agent ever reads it; the parent gets the
    # helper's two-sentence answer instead.
    def get_forecast(city, days)
      loc = Weather.geocode(city)
      return "Couldn't find a location matching '#{city}'." unless loc

      uri = URI("https://api.open-meteo.com/v1/forecast")
      uri.query = URI.encode_www_form(
        latitude: loc[:lat], longitude: loc[:lon],
        hourly: "temperature_2m,precipitation_probability,wind_speed_10m,weather_code",
        temperature_unit: "fahrenheit", wind_speed_unit: "mph",
        forecast_days: days
      )
      resp = Net::HTTP.get_response(uri)
      return "Forecast API returned status #{resp.code}." unless resp.is_a?(Net::HTTPSuccess)

      resp.body
    rescue => e
      "Error fetching forecast: #{e.message}"
    end
  end
end
