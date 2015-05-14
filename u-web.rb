#!/usr/bin/env ruby
############################################################################
# U::Web - micro web-framework for fun
# ------------------------------------
#
# The goal was to pack as much features as possible in a single file without
# compromising on the coding style too much.
#
# The first part of the file defines a MVC web framework including a router,
# custom dispatch, an in-memeory database and pure ruby html views with easy
# support for layouts.
#
# The second part of the file implements a demo application.
# To try it out run the following in the console:
#
#     ln -s u-web.rb Gemfile
#     ln -s u-web.rb config.ru
#     bundle
#     bundle exec rackup
#
# And then navigate to http://localhost:9292/
#
# Cheers,
#   z
############################################################################

require 'forwardable'
require 'set'

module U
  # A very simple MVC web framework
  module Web
    # Module-level router, setup on inclusion of UWeb
    extend Forwardable
    attr_accessor :router
    def_delegators :@router, :default, :map, :call

    def self.extended(klass)
      %w(rack mime/types yaml).each(&method(:require))
      klass.router = Router.new
    end

    def self.included(klass)
      klass.extend self
    end

    MIME_MAP = {
      html: 'text/html',
      text: 'text/plain',
      json: 'application/json',
    }.tap do |h|
      h.default_proc = ->(_, x) { x }
    end

    # Very simple O(N) router
    class Router
      def initialize
        @routes = {}
        @default = NotFound
      end

      # Sets the default controller to use when no route is matching.
      attr_writer :default
      alias_method :default, :default=

      # Associates a path to a controller
      #
      # +path+ is either a regexp or a string
      # +controller+ is a UWeb::C or any Rack app
      def map(path, controller)
        unless path.is_a?(Regexp) # Allow for custom regexp
          path = /\A#{path.gsub(/:(\w+)/, '(?<\1>[^/]+)')}\z/
        end
        @routes[path] = controller
      end

      # Dispatch
      def call(env)
        @routes.each do |path, controller|
          md = path.match(env['REQUEST_PATH'])
          next unless md

          if md.names.any?
            env['uweb.kwargs'] = Hash[
              md.names.map(&:to_sym).zip(md.captures)
            ]
          else
            env['uweb.args'] = md.captures
          end

          return controller.call(env)
        end
        @default.call(env)
      end
    end

    # M like Model
    #
    # In-memory database
    class M
      RecordNotFound = Class.new(StandardError)

      @attributes = Set.new

      # AR-like class-level repository of items
      class << self
        def inherited(klass)
          klass.instance_variable_set(:@items, Set.new)
          klass.instance_variable_set(:@attributes, @attributes.clone)
        end

        attr_reader :items

        def all
          @items.to_a
        end

        def delete(item)
          @items.delete(item)
        end

        def delete_all
          @items.clear
        end

        # Simple O(N) search
        def find(id)
          safe_find(id) || fail(RecordNotFound, id)
        end

        def safe_find(id)
          @items.detect { |item| item.id == id }
        end

        def save(item)
          item.id ||= SecureRandom.uuid
          item.before_save
          @items.add(item)
          item.after_save
        end


        attr_reader :attributes

        # Helper method for attributes. Might add change-tracking.
        def attribute(name)
          @attributes.add(name.to_sym)
          attr_accessor name
        end
      end

      attribute :id

      def initialize(data = {})
        merge!(data)
      end

      def attributes
        self.class.attributes
      end

      def merge!(data, replace: false)
        attributes.each do |key|
          if replace || data.key?(key) || data.key?(key.to_s)
            public_send("#{key}=", data.fetch(key) { data[key.to_s] })
          end
        end
      end

      def before_save
      end

      def after_save
      end
    end

    # V like View
    #
    # Small pure-ruby templating language.
    #
    # Limited by stack depth. Doesn't do any escaping of attributes or values.
    class V
      class Tag
        attr_reader :name, :content, :attributes

        def initialize(name, content, attributes)
          @name = name
          @content = content
          @attributes = attributes
        end

        def to_a
          attrs = attributes
            .map do |k, v|
              case v
              when true then k
              when false then nil
              else [k, v].join('="') + '"'
              end
            end
            .compact

          x = ["<#{([name] + attrs).join(' ')}>"]
          if content.compact.any?
            x << content
              .map { |c| c.respond_to?(:to_a) ? c.to_a : c.lines.map(&:strip) }
              .flatten
              .map { |c| '  ' + c }
            x << "</#{name}>"
          end
          x
        end
      end

      def initialize(**ivars)
        ivars.each_pair do |k, v|
          instance_variable_set(k, v)
        end
        @_top = nil
        @_current = nil
      end

      def text(content)
        @_current.content << content
      end

      def to_s
        render unless @_top
        "<!doctype html>\n" + @_top.to_a.join("\n")
      end

      # Conflicts with Kernel#p
      undef_method :p

      def method_missing(tag, *content, **attributes, &child)
        tag = Tag.new(tag, content, attributes)
        if @_top.nil?
          @_top = @_current = tag
        else
          @_current.content << tag
        end
        if block_given?
          parent, @_current = @_current, tag
          instance_eval(&child)
          @_current = parent
        end
        tag
      end
    end

    # C like Controller
    class C
      class << self
        def call(env)
          new(env).to_a
        end

        def attr_conf(*names)
          names.each do |name|
            attr_writer name
            define_method(name) do |*a|
              instance_variable_set("@#{name}", a.first) unless a.empty?
              instance_variable_get("@#{name}")
            end
            protected name
          end
        end
      end

      attr_reader :env, :request, :headers
      attr_conf :status, :body
      alias_method :to_i, :status

      def initialize(env)
        @env = env
        @request = Rack::Request.new(env)
        @status = 200
        @headers = {}
        @body = []
        action
      end

      def to_a
        [@status, @headers, Array(@body)]
      end

      protected

      # Internal dispatch
      def action
        kwargs = env['uweb.kwargs']
        if kwargs && kwargs.any?
          public_send(
            env['REQUEST_METHOD'].upcase,
            *(env['uweb.args'] || []),
            **kwargs,
          )
        else
          public_send(
            env['REQUEST_METHOD'].upcase,
            *(env['uweb.args'] || []),
          )
        end
      rescue M::RecordNotFound
        @status, @headers, @body = NotFound.new(@env).to_a
      end

      # Sets the content-type of the response
      def content_type(type)
        type = MIME_MAP[type]
        @headers['Content-Type'] = MIME::Types[type].first.content_type
      end

      # Renders a given templace class and sets the Content-Type to text/html
      def render(template, locals = nil)
        locals ||= instance_variables.each_with_object({}) do |ivar, h|
          h[ivar] = instance_variable_get(ivar)
        end
        content_type :html
        body template.new(locals).to_s
      end
    end

    # Default route when not paths are matching
    class NotFound < C
      def action
        status 404
        content_type :text
        body format('Page %s not found', request.path)
      end
    end
  end
end

##############################################################################

case File.basename(__FILE__)
when 'Gemfile' then
  source 'https://rubygems.org'
  gem 'rack'
  gem 'mime-types'
  gem 'json'
when 'config.ru' then
  require 'json'
  module MyApp
    include U::Web

    class TodoUI < C
      def GET
        render Dashboard
      end
    end

    module Helpers
      protected

      def render_json(item)
        if item.nil?
          status 404
          item = { error: 'not-found' }
        end

        content_type :json
        body JSON.dump(item)
      end

      def present(item)
        case item
        when Enumerable
          present_collection(item)
        when Todo
          present_todo(item)
        when nil
          nil
        else
          fail "No presenter for #{item.inspect}"
        end
      end

      private

      def present_collection(items)
        items.map{ |item| present(item) }
      end

      def present_todo(todo)
        obj = {}
        Todo.attributes.each do |key|
          obj[key.to_s] = todo.public_send(key)
        end
        obj['url'] = URI(env['REQUEST_URI'])
          .tap{ |uri| uri.path = "/todos/#{todo.id}" }
        obj
      end
    end

    class TodoCollection < C
      include Helpers

      def GET
        render_json present(Todo.all)
      end

      def DELETE
        status 204
        render_json present(Todo.delete_all)
      end

      def POST
        status 201
        params = JSON.parse(request.body.read)

        id = params['id']
        if id
          todo = Todo.find(id)
          todo.merge!(params)
        else
          todo = Todo.new(params)
        end

        Todo.save(todo)

        render_json present(todo)
      end
    end

    class TodoItem < C
      include Helpers
      def GET(id:)
        todo = Todo.find(id)
        render_json present(todo)
      end

      def PATCH(id:)
        params = JSON.parse(request.body.read)

        todo = Todo.find(id)
        todo.merge!(params)

        Todo.save(todo)

        render_json present(todo)
      end

      def PUT(id:)
        params = JSON.parse(request.body.read)

        todo = Todo.find(id)
        todo.merge!(params, replace: true)

        Todo.save(todo)

        render_json present(todo)
      end

      def DELETE(id:)
        status 204
        todo = Todo.safe_find(id)
        Todo.delete(todo) if todo
      end
    end

    class Todo < M
      attribute :title
      #attribute :url
      attribute :completed
    end

    class Layout < V
      def todo(path)
        "http://www.todobackend.com/client/#{path}"
      end

      def render
        html lang: 'en', 'data-framework': 'backbonejs' do
          head do
            meta charset: 'utf-8'
            title 'Todo-Backend client'
            link rel: 'stylesheet', href: todo('css/vendor/todomvc-common.css')
            link rel: 'stylesheet', href: todo('css/chooser.css')
            style <<-STYLE
              #todo-list li label {
                white-space: nowrap;
              }
            STYLE
          end
          body do
            content
          end
        end
      end
    end

    class Dashboard < Layout
      def content
        section id: 'api-root' do
          div class: 'wrapper' do
            label 'Todo-Backend api root', for: 'api-root-url'
            input id: 'api-root-url', placeholder: '/todos', value: '/todos'
          end
          button 'go'
        end

        section id: 'target-info' do
          h2 do
            text 'client connected to: '
            span '', class: 'target-url'
          end
        end

        section id: 'todoapp' do
          header id: 'header' do
            h1 'todos'
            input(
              id: 'new-todo',
              placeholder: 'What needs to be done?',
              autofocus: true,
            )
          end
          section id: 'main' do
            input id: 'toggle-all', type: 'checkbox'
            label 'Mark all as complete', for: 'toggle-all'
            ul '', id: 'todo-list'
          end
          footer '', id: 'footer'
        end

        footer id: 'info' do
          p 'Double-click to edit a todo'
          p do
            text 'Written by '
            a 'Addy Osmani', href: 'https://github.com/addyosmani'
            text ', modified by '
            a 'Pete Hodgson', href: 'https://github.com/moredip'
            text ' to be integrated with a '
            a 'TodoBackend API', href: 'http://www.todobackend.com'
            text '.'
          end
          p do
            text 'Part of '
            a 'TodoMVC', href: 'http://todomvc.com'
            text ' &amp; '
            a 'TodoBackend', href: 'http://www.todobackend.com'
          end
        end
        script type: 'text/template', id: 'item-template' do
          div class: 'view' do
            text "<input class=toggle type=checkbox <%= completed ? 'checked' : '' %>>"
            label '<%- title %>'
            button class: 'destroy'
          end
          input class: 'edit', value: '<%- title %>'
        end
        script type: 'text/template', id: 'stats-template' do
          span id: 'todo-count' do
            strong '<%= remaining %>'
            text " <%= remaining === 1 ? 'item' : 'items' %> left"
          end
          ul id: 'filters' do
            li do
              a 'All', class: 'selected', href: '#/'
            end
            li do
              a 'Active', href: '#/active'
            end
            li do
              a 'Completed', href: '#/completed'
            end
          end
          text '<% if (completed) { %>'
          button 'Clear completed (<%= completed %>)', id: 'clear-completed'
          text '<% } %>'
        end

        script '', src: todo('js/vendor/todomvc-common.js')
        script '', src: todo('js/vendor/todomvc-common.js')
        script '', src: todo('js/vendor/jquery.js')
        script '', src: todo('js/vendor/underscore.js')
        script '', src: todo('js/vendor/backbone.js')

        script '', src: todo('js/models/todo.js')
        script '', src: todo('js/collections/todos.js')
        script '', src: todo('js/views/todo-view.js')
        script '', src: todo('js/views/app-view.js')
        script '', src: todo('js/routers/router.js')
        script '', src: todo('js/app.js')
      end
    end

    map '/', TodoUI
    map '/todos', TodoCollection
    map '/todos/:id', TodoItem
  end

  run MyApp
end
