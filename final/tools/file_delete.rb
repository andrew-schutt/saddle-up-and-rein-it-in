module Tools
  module FileDelete
    DANGEROUS = true

    SCHEMA = {
      name: "delete_file",
      description: "Delete the file at the given path.",
      input_schema: {
        type: "object",
        properties: {
          path: {
            type: "string",
            description: "The path of the file to delete."
          }
        },
        required: ["path"]
      }
    }.freeze

    module_function

    # Stubbed for the demo — reports what it would do without touching
    # the filesystem.
    def call(input)
      "[stub] Would delete: #{input[:path]}"
    end
  end
end
