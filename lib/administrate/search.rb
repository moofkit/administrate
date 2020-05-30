require "active_support/core_ext/module/delegation"
require "active_support/core_ext/object/blank"

module Administrate
  class Search
    class Query
      attr_reader :filters

      def blank?
        terms.blank? && filters.empty?
      end

      def initialize(original_query)
        @original_query = original_query
        @filters, @terms = parse_query(original_query)
      end

      def original
        @original_query
      end

      def terms
        @terms.join(" ")
      end

      def to_s
        original
      end

      private

      def filter?(word)
        word.match?(/^\w+:$/)
      end

      def parse_query(query)
        filters = []
        terms = []
        query.to_s.split.each do |word|
          if filter?(word)
            filters << word.split(":").first
          else
            terms << word
          end
        end
        [filters, terms]
      end
    end

    def self.define_search_mode(dashboard_class)
      if dashboard_class.const_defined?(:FILTER_MODE)
        dashboard_class.const_get(:FILTER_MODE)
      else
        :fuzzy
      end
    end

    def self.run(scoped_resource, dashboard_class, term)
      if define_search_mode(dashboard_class) == :strict
        StrictSearch
      else
        FuzzySearch
      end.new(scoped_resource, dashboard_class, term).run
    end

    def initialize(scoped_resource, dashboard_class, term)
      @dashboard_class = dashboard_class
      @scoped_resource = scoped_resource
      @query = Query.new(term)
    end

    def run
      if query.blank?
        @scoped_resource.all
      else
        results = search_results(@scoped_resource)
        results = filter_results(results)
        results
      end
    end

    private

    def apply_filter(filter, resources)
      return resources unless filter
      filter.call(resources)
    end

    def filter_results(resources)
      query.filters.each do |filter_name|
        filter = valid_filters[filter_name]
        resources = apply_filter(filter, resources)
      end
      resources
    end

    def query_template
      search_attributes.map do |attr|
        table_name = query_table_name(attr)

        searchable_fields(attr).map do |field|
          attr_name = column_to_query(field)
          query_string(table_name, attr_name)
        end.join(" OR ")
      end.join(" OR ")
    end

    def searchable_fields(attr)
      return [attr] unless association_search?(attr)

      attribute_types[attr].searchable_fields
    end

    def fields_count
      search_attributes.sum do |attr|
        searchable_fields(attr).count
      end
    end

    def search_attributes
      attribute_types.keys.select do |attribute|
        attribute_types[attribute].searchable?
      end
    end

    def search_results(resources)
      resources.
        joins(tables_to_join).
        where(query_template, *query_values)
    end

    def valid_filters
      if @dashboard_class.const_defined?(:COLLECTION_FILTERS)
        @dashboard_class.const_get(:COLLECTION_FILTERS).stringify_keys
      else
        {}
      end
    end

    def attribute_types
      @dashboard_class::ATTRIBUTE_TYPES
    end

    def query_table_name(attr)
      if association_search?(attr)
        provided_class_name = attribute_types[attr].options[:class_name]
        if provided_class_name
          provided_class_name.constantize.table_name
        else
          ActiveRecord::Base.connection.quote_table_name(attr.to_s.pluralize)
        end
      else
        ActiveRecord::Base.connection.
          quote_table_name(@scoped_resource.table_name)
      end
    end

    def column_to_query(attr)
      ActiveRecord::Base.connection.quote_column_name(attr)
    end

    def tables_to_join
      attribute_types.keys.select do |attribute|
        attribute_types[attribute].searchable? && association_search?(attribute)
      end
    end

    def association_search?(attribute)
      attribute_types[attribute].associative?
    end

    def term
      query.terms
    end

    attr_reader :resolver, :query
  end

  class StrictSearch < Search
    def query_values
      [term] * fields_count
    end

    def query_string(table_name, attr_name)
      "#{table_name}.#{attr_name} = ?"
    end
  end

  class FuzzySearch < Search
    def query_values
      ["%#{term.mb_chars.downcase}%"] * fields_count
    end

    def query_string(table_name, attr_name)
      "LOWER(CAST(#{table_name}.#{attr_name} AS CHAR(256))) LIKE ?"
    end
  end
end
