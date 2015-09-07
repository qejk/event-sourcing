
# ============== INTEGRATION SETUP =============== #
class @CustomerApp extends Space.Application

  RequiredModules: ['Space.eventSourcing']

  Dependencies:
    commandBus: 'Space.messaging.CommandBus'
    eventBus: 'Space.messaging.EventBus'
    configuration: 'Space.eventSourcing.Configuration'
    Mongo: 'Mongo'

  Singletons: [
    'CustomerApp.CustomerRegistrationRouter'
    'CustomerApp.CustomerRouter'
    'CustomerApp.EmailRouter'
    'CustomerApp.CustomerRegistrationProjection'
  ]

  configure: ->
    @configuration.useInMemoryCollections = true
    collection = new @Mongo.Collection(null)
    @injector.map('CustomerApp.CustomerRegistrations').to collection
    # Setup snapshotting
    @snapshots = new @Mongo.Collection(null)
    @snapshotter = new Space.eventSourcing.Snapshotter {
      collection: @snapshots
      versionFrequency: 2
    }

  startup: ->
    @injector.get('Space.eventSourcing.Repository').useSnapshotter @snapshotter
    @resetDatabase()

  sendCommand: -> @commandBus.send.apply @commandBus, arguments

  subscribeTo: -> @eventBus.subscribeTo.apply @eventBus, arguments

  resetDatabase: ->
    @commits = @injector.get 'Space.eventSourcing.Commits'
    @commits.remove {}

# -------------- COMMANDS ---------------

Space.messaging.define Space.messaging.Command, 'CustomerApp', {

  RegisterCustomer:
    registrationId: String
    customerId: String
    customerName: String

  CreateCustomer:
    customerId: String
    name: String

  SendWelcomeEmail:
    customerId: String
    customerName: String
}

# --------------- EVENTS ---------------

Space.messaging.define Space.messaging.Event, 'CustomerApp', {

  RegistrationInitiated:
    sourceId: String
    version: Match.Optional(Match.Integer)
    customerId: String
    customerName: String

  CustomerCreated:
    sourceId: String
    version: Match.Optional(Match.Integer)
    customerName: String

  WelcomeEmailTriggered:
    sourceId: String
    version: Match.Optional(Match.Integer)
    customerId: String

  WelcomeEmailSent:
    sourceId: String
    version: Match.Optional(Match.Integer)
    customerId: String
    email: String

  RegistrationCompleted:
    sourceId: String
    version: Match.Optional(Match.Integer)
}

# -------------- AGGREGATES ---------------

class CustomerApp.Customer extends Space.eventSourcing.Aggregate

  @FIELDS:
    name: null

  initialize: (id, data) ->

    @record new CustomerApp.CustomerCreated
      sourceId: id
      customerName: data.name

  @handle CustomerApp.CustomerCreated, (event) -> @name = event.customerName

# -------------- PROCESSES ---------------

class CustomerApp.CustomerRegistration extends Space.eventSourcing.Process

  @FIELDS:
    customerId: null
    customerName: null

  @STATES:
    creatingCustomer: 0
    sendingWelcomeEmail: 1
    completed: 2

  initialize: (id, data) ->

    @trigger new CustomerApp.CreateCustomer
      customerId: data.customerId
      name: data.customerName

    @record new CustomerApp.RegistrationInitiated
      sourceId: id
      customerId: data.customerId
      customerName: data.customerName

  onCustomerCreated: (event) ->

    @trigger new CustomerApp.SendWelcomeEmail
      customerId: @customerId
      customerName: @customerName

    @record new CustomerApp.WelcomeEmailTriggered
      sourceId: @getId()
      customerId: @customerId

  onWelcomeEmailSent: (event) ->
    @record new CustomerApp.RegistrationCompleted sourceId: @getId()

  @handle CustomerApp.RegistrationInitiated, (event) ->
    { @customerId, @customerName } = event
    @_state = CustomerApp.CustomerRegistration.STATES.creatingCustomer

  @handle CustomerApp.WelcomeEmailTriggered, ->
    @_state = CustomerApp.CustomerRegistration.STATES.sendingWelcomeEmail

  @handle CustomerApp.RegistrationCompleted, ->
    @_state = CustomerApp.CustomerRegistration.STATES.completed

# -------------- ROUTERS --------------- #

class CustomerApp.CustomerRegistrationRouter extends Space.messaging.Controller

  Dependencies:
    repository: 'Space.eventSourcing.Repository'
    registrations: 'CustomerApp.CustomerRegistrations'

  @handle CustomerApp.RegisterCustomer, (command) ->
    registration = new CustomerApp.CustomerRegistration command.registrationId, command
    @repository.save registration

  @on CustomerApp.CustomerCreated, (event) ->
    registration = @_findRegistrationByCustomerId event.sourceId
    registration.onCustomerCreated event
    @repository.save registration

  @on CustomerApp.WelcomeEmailSent, (event) ->
    registration = @_findRegistrationByCustomerId event.customerId
    registration.onWelcomeEmailSent()
    @repository.save registration

  _findRegistrationByCustomerId: (customerId) ->
    registrationId = @registrations.findOne(customerId: customerId)._id
    return @repository.find CustomerApp.CustomerRegistration, registrationId


class CustomerApp.CustomerRouter extends Space.messaging.Controller

  @toString: -> 'CustomerApp.CustomerRouter'

  Dependencies:
    repository: 'Space.eventSourcing.Repository'

  @handle CustomerApp.CreateCustomer, (command) ->
    @repository.save new CustomerApp.Customer command.customerId, command


class CustomerApp.EmailRouter extends Space.messaging.Controller

  @toString: -> 'CustomerApp.EmailRouter'

  Dependencies:
    eventBus: 'Space.messaging.EventBus'

  @handle CustomerApp.SendWelcomeEmail, (command) ->

    # simulate sub-system sending emails
    @eventBus.publish new CustomerApp.WelcomeEmailSent
      sourceId: '999'
      version: 1
      customerId: command.customerId
      email: "Hello #{command.customerName}"

# -------------- VIEW PROJECTIONS --------------- #

class CustomerApp.CustomerRegistrationProjection extends Space.messaging.Controller

  Dependencies:
    registrations: 'CustomerApp.CustomerRegistrations'

  @on CustomerApp.RegistrationInitiated, (event) ->

    @registrations.insert
      _id: event.sourceId
      customerId: event.customerId
      customerName: event.customerName
      isCompleted: false

  @on CustomerApp.RegistrationCompleted, (event) ->

    @registrations.update { _id: event.sourceId }, $set: isCompleted: true


# ============== INTEGRATION TESTING =============== #

describe.server 'Space.eventSourcing (integration)', ->

  # fixtures
  customer = id: 'customer_123', name: 'Dominik'
  registration = id: 'registration_123'

  beforeEach ->
    @app = new CustomerApp()
    @app.start()

  it 'handles commands and publishes events correctly', ->
    registrationInitiatedSpy = sinon.spy()
    customerCreatedSpy = sinon.spy()
    welcomeEmailTriggeredSpy = sinon.spy()
    welcomeEmailSentSpy = sinon.spy()
    registrationCompletedSpy = sinon.spy()

    @app.subscribeTo CustomerApp.RegistrationInitiated, registrationInitiatedSpy
    @app.subscribeTo CustomerApp.CustomerCreated, customerCreatedSpy
    @app.subscribeTo CustomerApp.WelcomeEmailTriggered, welcomeEmailTriggeredSpy
    @app.subscribeTo CustomerApp.WelcomeEmailSent, welcomeEmailSentSpy
    @app.subscribeTo CustomerApp.RegistrationCompleted, registrationCompletedSpy

    @app.sendCommand new CustomerApp.RegisterCustomer
      registrationId: registration.id
      customerId: customer.id
      customerName: customer.name

    expect(registrationInitiatedSpy).to.have.been.calledWithMatch(
      new CustomerApp.RegistrationInitiated
        sourceId: registration.id
        version: 1
        customerId: customer.id
        customerName: customer.name
    )

    expect(customerCreatedSpy).to.have.been.calledWithMatch(
      new CustomerApp.CustomerCreated
        sourceId: customer.id
        version: 1
        customerName: customer.name
    )

    expect(welcomeEmailTriggeredSpy).to.have.been.calledWithMatch(
      new CustomerApp.WelcomeEmailTriggered
        sourceId: registration.id
        version: 2
        customerId: customer.id
    )

    expect(welcomeEmailSentSpy).to.have.been.calledWithMatch(
      new CustomerApp.WelcomeEmailSent
        sourceId: '999'
        version: 1
        email: "Hello #{customer.name}"
        customerId: customer.id
    )

    expect(registrationCompletedSpy).to.have.been.calledWithMatch(
      new CustomerApp.RegistrationCompleted
        sourceId: registration.id
        version: 3
    )

    # Check snapshots
    expect(@app.snapshots.find().fetch()).toMatch [
      {
        _id: "registration_123",
        snapshot: {
          id: "registration_123",
          state: 2,
          version: 2,
          customerId: "customer_123",
          customerName: "Dominik"
        }
      },
      {
        _id: "customer_123",
        snapshot: {
          id: "customer_123",
          state: null,
          version: 0,
          name: "Dominik"
        }
      }
    ]
