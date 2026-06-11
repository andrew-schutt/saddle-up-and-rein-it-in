require "net/http"
require "json"
require "uri"

module Tools
  module Weather
    SCHEMA = {
      name: "get_weather",
      description: "Get the current weather for a given city.",
      input_schema: {
        type: "object",
        properties: {
          city: {
            type: "string",
            description: "The name of the city to get the weather for."
          }
        },
        required: ["city"]
      }
    }.freeze

    WMO_CODES = {
      0 => "clear sky",
      1 => "mainly clear", 2 => "partly cloudy", 3 => "overcast",
      45 => "fog", 48 => "depositing rime fog",
      51 => "light drizzle", 53 => "moderate drizzle", 55 => "dense drizzle",
      61 => "light rain", 63 => "moderate rain", 65 => "heavy rain",
      71 => "light snow", 73 => "moderate snow", 75 => "heavy snow",
      77 => "snow grains",
      80 => "light rain showers", 81 => "moderate rain showers", 82 => "violent rain showers",
      85 => "light snow showers", 86 => "heavy snow showers",
      95 => "thunderstorm", 96 => "thunderstorm with light hail", 99 => "thunderstorm with heavy hail"
    }.freeze

    module_function

    def call(input)
      get_weather(input[:city])
    end

    def get_weather(city)
      loc = geocode(city)
      return "Couldn't find a location matching '#{city}'." unless loc

      uri = URI("https://api.open-meteo.com/v1/forecast")
      uri.query = URI.encode_www_form(
        latitude: loc[:lat], longitude: loc[:lon],
        current: "temperature_2m,weather_code,wind_speed_10m",
        temperature_unit: "fahrenheit", wind_speed_unit: "mph"
      )
      resp = Net::HTTP.get_response(uri)
      return "Weather API returned status #{resp.code}." unless resp.is_a?(Net::HTTPSuccess)

      current = JSON.parse(resp.body)["current"]
      return "Weather data unavailable for #{loc[:name]}." unless current

      desc = WMO_CODES.fetch(current["weather_code"], "unknown conditions")
      "#{loc[:name]}, #{loc[:country]}: #{desc}, " \
        "#{current["temperature_2m"]}°F, wind #{current["wind_speed_10m"]} mph."
    rescue => e
      "Error fetching weather: #{e.message}"
    end

    def geocode(city)
      uri = URI("https://geocoding-api.open-meteo.com/v1/search")
      uri.query = URI.encode_www_form(name: city, count: 1)
      resp = Net::HTTP.get_response(uri)
      return nil unless resp.is_a?(Net::HTTPSuccess)

      result = JSON.parse(resp.body)["results"]&.first
      return nil unless result

      { lat: result["latitude"], lon: result["longitude"],
        name: result["name"], country: result["country"] }
    end
  end
end
