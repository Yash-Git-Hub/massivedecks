module MassiveDecks.Pages.Lobby exposing
    ( changeRoute
    , init
    , route
    , subscriptions
    , update
    , view
    )

import Browser.Navigation as Navigation
import Dict exposing (Dict)
import FontAwesome.Attributes as Icon
import FontAwesome.Brands as Icon
import FontAwesome.Icon as Icon exposing (Icon)
import FontAwesome.Layering as Icon
import FontAwesome.Solid as Icon
import Html exposing (Html)
import Html.Attributes as HtmlA
import Html.Events as HtmlE
import Html.Keyed as HtmlK
import MassiveDecks.Animated as Animated exposing (Animated)
import MassiveDecks.Card.Model as Card
import MassiveDecks.Cast.Model as Cast
import MassiveDecks.Components as Components
import MassiveDecks.Components.Menu as Menu
import MassiveDecks.Error.Messages as Error
import MassiveDecks.Error.Model as Error
import MassiveDecks.Game as Game
import MassiveDecks.Game.Model as Game exposing (Game)
import MassiveDecks.Game.Player as Player exposing (Player)
import MassiveDecks.Game.Round as Round exposing (Round)
import MassiveDecks.Messages as Global
import MassiveDecks.Model exposing (..)
import MassiveDecks.Models.MdError as MdError exposing (MdError)
import MassiveDecks.Pages.Lobby.Configure as Configure
import MassiveDecks.Pages.Lobby.Configure.Model as Configure exposing (Config)
import MassiveDecks.Pages.Lobby.Events as Events
import MassiveDecks.Pages.Lobby.GameCode as GameCode
import MassiveDecks.Pages.Lobby.Invite as Invite
import MassiveDecks.Pages.Lobby.Messages exposing (..)
import MassiveDecks.Pages.Lobby.Model exposing (..)
import MassiveDecks.Pages.Lobby.Route exposing (..)
import MassiveDecks.Pages.Lobby.Token as Token
import MassiveDecks.Pages.Route as Route
import MassiveDecks.Pages.Start.Route as Start
import MassiveDecks.ServerConnection as ServerConnection
import MassiveDecks.Settings as Settings
import MassiveDecks.Settings.Messages as Settings
import MassiveDecks.Settings.Model as Settings exposing (Settings)
import MassiveDecks.Strings as Strings exposing (MdString)
import MassiveDecks.Strings.Languages as Lang
import MassiveDecks.User as User exposing (User)
import MassiveDecks.Util as Util
import MassiveDecks.Util.Html as Html
import MassiveDecks.Util.Html.Attributes as HtmlA
import MassiveDecks.Util.Maybe as Maybe
import MassiveDecks.Util.Result as Result
import Weightless as Wl
import Weightless.Attributes as WlA


changeRoute : Route -> Model -> ( Model, Cmd Global.Msg )
changeRoute r model =
    ( { model | route = r, lobby = Nothing }, Cmd.none )


init : Shared -> Route -> Maybe Auth -> Route.Fork ( Model, Cmd Global.Msg )
init shared r auth =
    let
        fallbackAuth =
            Maybe.first
                [ auth |> Maybe.andThen (Maybe.validate (\a -> a.claims.gc == r.gameCode))
                , Settings.auths shared.settings.settings |> Dict.get (r.gameCode |> GameCode.toString)
                ]
    in
    fallbackAuth
        |> Maybe.map
            (\a ->
                Route.Continue
                    ( { route = r
                      , auth = a
                      , lobby = Nothing
                      , configure = Configure.init
                      , notificationId = 0
                      , notifications = []
                      , inviteDialogOpen = False
                      }
                    , ServerConnection.connect a.claims.gc a.token
                    )
            )
        |> Maybe.withDefault (Route.Redirect (Route.Start { section = Start.Join (Just r.gameCode) }))


route : Model -> Route
route model =
    model.route


subscriptions : Model -> Sub Global.Msg
subscriptions model =
    Sub.batch
        [ model.lobby |> Maybe.andThen .game |> Maybe.map Game.subscriptions |> Maybe.withDefault Sub.none
        , model.notifications |> Animated.subscriptions |> Sub.map (NotificationMsg >> Global.LobbyMsg)
        , ServerConnection.notifications
            eventPreprocess
            (ErrorReceived >> Global.LobbyMsg)
            (Error.Json >> Error.Add >> Global.ErrorMsg)
        ]


update : Shared -> Msg -> Model -> ( Model, Cmd Global.Msg )
update shared msg model =
    let
        key =
            shared.key
    in
    case msg of
        GameMsg gameMsg ->
            case model.lobby of
                Just l ->
                    l.game
                        |> Maybe.map
                            (Game.update shared gameMsg
                                >> Util.modelLift (\newGame -> { model | lobby = Just { l | game = Just newGame } })
                            )
                        |> Maybe.withDefault ( model, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        EventReceived event ->
            case model.lobby of
                Just lobby ->
                    case event of
                        Events.Sync { state, hand, play } ->
                            applySync model state hand play

                        Events.Configured configured ->
                            ( model.lobby
                                |> Maybe.map (\l -> applyConfigured configured l model)
                                |> Maybe.withDefault model
                            , Cmd.none
                            )

                        Events.GameStarted { round, hand } ->
                            Util.modelLift
                                (\g -> { model | lobby = Just { lobby | game = Just g } })
                                (Game.applyGameStarted lobby round hand)

                        Events.Game gameEvent ->
                            lobby.game
                                |> Maybe.map
                                    (\game ->
                                        Util.modelLift
                                            (\g -> { model | lobby = Just { lobby | game = Just g } })
                                            (Game.applyGameEvent model.auth shared gameEvent game)
                                    )
                                |> Maybe.withDefault ( model, Cmd.none )

                        Events.Connection { user, state } ->
                            let
                                message =
                                    case state of
                                        User.Connected ->
                                            UserConnected user

                                        User.Disconnected ->
                                            UserDisconnected user
                            in
                            addNotification message model

                        Events.Presence { user, state } ->
                            let
                                newUsers =
                                    case state of
                                        Events.UserJoined { name, privilege, control } ->
                                            Dict.insert
                                                user
                                                { name = name
                                                , presence = User.Joined
                                                , connection = User.Connected
                                                , privilege = privilege
                                                , role = User.Player
                                                , control = control
                                                }
                                                lobby.users

                                        Events.UserLeft ->
                                            lobby.users
                                                |> Dict.update user (Maybe.map (\u -> { u | presence = User.Left }))

                                message =
                                    case state of
                                        Events.UserJoined _ ->
                                            UserJoined user

                                        Events.UserLeft ->
                                            UserLeft user
                            in
                            addNotification message { model | lobby = Just { lobby | users = newUsers } }

                        Events.PrivilegeSet { user, privilege } ->
                            let
                                users =
                                    lobby.users |> Dict.update user (Maybe.map (\u -> { u | privilege = privilege }))
                            in
                            ( { model | lobby = Just { lobby | users = users } }, Cmd.none )

                Nothing ->
                    case event of
                        Events.Sync { state, hand, play } ->
                            applySync model state hand play

                        _ ->
                            ( model, Cmd.none )

        ErrorReceived error ->
            case error of
                MdError.Authentication reason ->
                    let
                        redirectTo =
                            Route.Start { section = Start.Join (Just model.auth.claims.gc) }
                    in
                    ( model, redirectTo |> Route.url |> Navigation.pushUrl key )

                _ ->
                    ( model, Cmd.none )

        ConfigureMsg configureMsg ->
            case model.lobby of
                Just l ->
                    Util.modelLift (\c -> { model | configure = c })
                        (Configure.update configureMsg model.configure l.config)

                Nothing ->
                    ( model, Cmd.none )

        NotificationMsg notificationMsg ->
            Util.lift
                (\notifications -> { model | notifications = notifications })
                (NotificationMsg >> Global.LobbyMsg)
                (Animated.update { removeDone = Just Animated.defaultDuration } notificationMsg model.notifications)

        ToggleInviteDialog ->
            ( { model | inviteDialogOpen = not model.inviteDialogOpen }, Cmd.none )


view : Shared -> Model -> List (Html Global.Msg)
view shared model =
    let
        usersShown =
            shared.settings.settings.openUserList

        castAttrs =
            case shared.castStatus of
                Cast.NoDevicesAvailable ->
                    Nothing

                Cast.NotConnected ->
                    Just [ Strings.Cast |> Lang.title shared ]

                Cast.Connecting ->
                    Just [ Strings.CastConnecting |> Lang.title shared, HtmlA.class "connecting" ]

                Cast.Connected name ->
                    Just [ Strings.CastConnected { deviceName = name } |> Lang.title shared, HtmlA.class "connected" ]

        castButton =
            castAttrs
                |> Maybe.map (viewCastButton model.auth)
                |> Maybe.withDefault []

        usersIcon =
            if usersShown then
                Icon.eyeSlash

            else
                Icon.users

        notifications =
            model.notifications |> List.map (keyedViewNotification shared model.lobby)
    in
    [ Html.div
        [ HtmlA.id "lobby"
        , HtmlA.classList [ ( "collapsed-users", not usersShown ) ]
        , shared.settings.settings.cardSize |> cardSizeToAttr
        ]
        (Html.div [ HtmlA.id "top-bar" ]
            [ Html.div [ HtmlA.class "left" ]
                (List.concat
                    [ [ Components.iconButtonStyled
                            [ HtmlE.onClick (usersShown |> not |> Settings.ChangeOpenUserList |> Global.SettingsMsg)
                            , Strings.ToggleUserList |> Lang.title shared
                            ]
                            ( [ Icon.lg ], usersIcon )
                      , lobbyMenu shared model.auth
                      ]
                    , castButton
                    ]
                )
            , Html.div [] [ Settings.view shared ]
            ]
            :: HtmlK.ol [ HtmlA.class "notifications" ] notifications
            :: (model.lobby
                    |> Maybe.map (viewLobby shared model.configure model.auth)
                    |> Maybe.withDefault
                        [ Html.div [ HtmlA.class "loading" ]
                            [ Icon.viewStyled [ Icon.spin, Icon.fa3x ] Icon.circleNotch ]
                        ]
               )
        )
    , Invite.dialog shared
        model.auth.claims.gc
        (model.lobby |> Maybe.andThen (.config >> .password))
        model.inviteDialogOpen
    ]



{- Private -}


cardSizeToAttr : Settings.CardSize -> Html.Attribute msg
cardSizeToAttr cardSize =
    case cardSize of
        Settings.Minimal ->
            HtmlA.class "minimal-card-size"

        Settings.Square ->
            HtmlA.class "square-card-size"

        Settings.Full ->
            HtmlA.nothing


eventPreprocess : Events.Event -> Global.Msg
eventPreprocess event =
    case event of
        Events.PrivilegeSet { token } ->
            Global.Batch
                [ token
                    |> Maybe.map (Token.decode >> Result.unifiedMap (Error.Token >> Error.Add >> Global.ErrorMsg) Global.UpdateToken)
                    |> Maybe.withDefault Global.NoOp
                , event |> EventReceived |> Global.LobbyMsg
                ]

        _ ->
            event |> EventReceived |> Global.LobbyMsg


lobbyMenu : Shared -> Auth -> Html Global.Msg
lobbyMenu shared auth =
    let
        id =
            "lobby-menu-button"

        lobbyMenuItems =
            [ Menu.button Icon.bullhorn Strings.InvitePlayers Strings.InvitePlayers (ToggleInviteDialog |> Global.LobbyMsg |> Just) ]

        userLobbyMenuItems =
            [ Menu.button Icon.userClock Strings.SetAway Strings.SetAway Nothing
            , Menu.button Icon.signOutAlt Strings.LeaveGame Strings.LeaveGame Nothing
            ]

        privilegedLobbyMenuItems =
            [ Menu.button Icon.stopCircle Strings.EndGame Strings.EndGameDescription Nothing
            ]

        mdMenuItems =
            [ Menu.link Icon.info Strings.AboutTheGame Strings.AboutTheGame (Just "https://github.com/lattyware/massivedecks")
            , Menu.link Icon.bug Strings.ReportError Strings.ReportError (Just "https://github.com/Lattyware/massivedecks/issues/new")
            ]

        menuItems =
            [ lobbyMenuItems |> Just
            , userLobbyMenuItems |> Just
            , privilegedLobbyMenuItems |> Maybe.justIf (auth.claims.pvg == User.Privileged)
            , mdMenuItems |> Just
            ]

        separatedMenuItems =
            menuItems |> List.filterMap identity |> List.intersperse [ Menu.Separator ] |> List.concat
    in
    Html.div []
        [ Components.iconButtonStyled [ HtmlA.id id, Strings.GameMenu |> Lang.title shared ]
            ( [ Icon.lg ], Icon.bars )
        , Menu.view shared id ( WlA.XCenter, WlA.YBottom ) ( WlA.XLeft, WlA.YTop ) separatedMenuItems
        ]


applyConfigured : { change : Events.ConfigChanged, version : String } -> Lobby -> Model -> Model
applyConfigured { change, version } oldLobby oldModel =
    let
        ( config, configure ) =
            Configure.applyChange change oldLobby.config oldModel.configure

        lobby =
            Just { oldLobby | config = { config | version = version } }
    in
    { oldModel | lobby = lobby, configure = configure }


notificationDuration : Int
notificationDuration =
    3500


applySync : Model -> Lobby -> Maybe (List Card.Response) -> Maybe (List Card.Id) -> ( Model, Cmd Global.Msg )
applySync model state hand pick =
    let
        play =
            pick |> Maybe.map (\cards -> { state = Round.Submitted, cards = cards }) |> Maybe.withDefault Round.noPick

        ( game, cmd ) =
            case state.game of
                Just g ->
                    Util.modelLift Just (Game.init g.game (hand |> Maybe.withDefault []) play)

                Nothing ->
                    ( Nothing, Cmd.none )
    in
    ( { model
        | lobby = Just { state | game = game }
        , configure = Configure.updateFromConfig state.config model.configure
      }
    , cmd
    )


addNotification : NotificationMessage -> Model -> ( Model, Cmd Global.Msg )
addNotification message model =
    let
        notification =
            { id = model.notificationId, message = message }

        notifications =
            model.notifications ++ [ Animated.animate notification ]
    in
    ( { model | notifications = notifications, notificationId = model.notificationId + 1 }
    , Animated.exitAfter notificationDuration notification
        |> Cmd.map (NotificationMsg >> Global.LobbyMsg)
    )


keyedViewNotification : Shared -> Maybe Lobby -> Animated Notification -> ( String, Html Global.Msg )
keyedViewNotification shared lobby notification =
    ( String.fromInt notification.item.id
    , Html.li [] [ Animated.view (viewNotification shared (lobby |> Maybe.map .users)) notification ]
    )


viewNotification : Shared -> Maybe (Dict User.Id User) -> Html.Attribute Global.Msg -> Notification -> Html Global.Msg
viewNotification shared users animationState notification =
    let
        ( icon, message ) =
            case notification.message of
                UserConnected id ->
                    ( Icon.viewIcon Icon.plug
                    , Strings.UserConnected { username = username shared users id } |> Lang.html shared
                    )

                UserDisconnected id ->
                    ( Icon.layers [] [ Icon.viewIcon Icon.plug, Icon.viewIcon Icon.slash ]
                    , Strings.UserDisconnected { username = username shared users id } |> Lang.html shared
                    )

                UserJoined id ->
                    ( Icon.viewIcon Icon.signInAlt
                    , Strings.UserJoined { username = username shared users id } |> Lang.html shared
                    )

                UserLeft id ->
                    ( Icon.viewIcon Icon.signOutAlt
                    , Strings.UserLeft { username = username shared users id } |> Lang.html shared
                    )
    in
    Wl.card
        [ HtmlA.class "notification", animationState ]
        [ Html.div [ HtmlA.class "content" ]
            [ Html.span [ HtmlA.class "icon" ] [ icon ]
            , Html.span [ HtmlA.class "message" ] [ message ]
            , Wl.button
                [ WlA.flat
                , WlA.inverted
                , notification |> Animated.Exit |> NotificationMsg |> Global.LobbyMsg |> HtmlE.onClick
                , HtmlA.class "action"
                ]
                [ Strings.Dismiss |> Lang.html shared ]
            ]
        ]


username : Shared -> Maybe (Dict User.Id User) -> User.Id -> String
username shared users id =
    users
        |> Maybe.andThen (\u -> Dict.get id u)
        |> Maybe.map .name
        |> Maybe.withDefault (Strings.UnknownUser |> Lang.string shared)


viewLobby : Shared -> Configure.Model -> Auth -> Lobby -> List (Html Global.Msg)
viewLobby shared configure auth lobby =
    let
        game =
            lobby.game |> Maybe.map .game

        privileged =
            auth.claims.pvg == User.Privileged
    in
    [ Html.div [ HtmlA.id "lobby-content" ]
        [ viewUsers shared auth.claims.uid lobby.users game
        , Html.div [ HtmlA.id "scroll-frame" ]
            [ lobby.game
                |> Maybe.map (Game.view shared auth lobby.name lobby.config lobby.users)
                |> Maybe.withDefault (Configure.view shared privileged configure auth.claims.gc lobby lobby.config)
            ]
        ]
    ]


viewUsers : Shared -> User.Id -> Dict User.Id User -> Maybe Game -> Html Global.Msg
viewUsers shared player users game =
    let
        ( active, inactive ) =
            users |> Dict.toList |> List.partition (\( _, user ) -> user.presence == User.Joined)

        activeGroups =
            active |> byRole |> List.map (viewRoleGroup shared player game)

        inactiveGroup =
            if List.isEmpty inactive then
                []

            else
                [ viewUserListGroup shared player game ( ( "left", Strings.Left ), inactive ) ]

        groups =
            List.concat [ activeGroups, inactiveGroup ]
    in
    Wl.card [ HtmlA.id "users" ]
        [ Html.div [ HtmlA.class "collapsible" ] [ HtmlK.ol [] groups ] ]


viewRoleGroup : Shared -> User.Id -> Maybe Game -> ( User.Role, List ( User.Id, User ) ) -> ( String, Html Global.Msg )
viewRoleGroup shared player game ( role, users ) =
    let
        idAndDescription =
            case role of
                User.Player ->
                    ( "players", Strings.Players )

                User.Spectator ->
                    ( "spectators", Strings.Spectators )
    in
    viewUserListGroup shared player game ( idAndDescription, users )


viewUserListGroup : Shared -> User.Id -> Maybe Game -> ( ( String, MdString ), List ( User.Id, User ) ) -> ( String, Html Global.Msg )
viewUserListGroup shared player game ( ( id, description ), users ) =
    ( id
    , Html.li [ HtmlA.class id ]
        [ Html.span [] [ description |> Lang.html shared ]
        , HtmlK.ol [] (users |> List.map (viewUser shared player game))
        ]
    )


roles : List User.Role
roles =
    [ User.Player, User.Spectator ]


byRole : List ( User.Id, User ) -> List ( User.Role, List ( User.Id, User ) )
byRole users =
    roles
        |> List.map (\role -> ( role, users |> List.filter (\( _, user ) -> user.role == role) ))
        |> List.filter (\( _, us ) -> not (List.isEmpty us))


viewUser : Shared -> User.Id -> Maybe Game -> ( User.Id, User ) -> ( String, Html Global.Msg )
viewUser shared player game ( userId, user ) =
    let
        ( secondary, score ) =
            userDetails shared game userId user

        id =
            "user-" ++ userId

        menuItems =
            if user.control == User.Human then
                let
                    privilegeMenuItems =
                        case user.privilege of
                            User.Unprivileged ->
                                Just [ Menu.button Icon.userPlus Strings.Promote Strings.Promote Nothing ]

                            User.Privileged ->
                                Just [ Menu.button Icon.userMinus Strings.Demote Strings.Demote Nothing ]

                    presenceMenuItems =
                        case user.presence of
                            User.Joined ->
                                Just
                                    [ Menu.button Icon.userClock Strings.SetAway Strings.SetAway Nothing
                                    , Menu.button Icon.ban Strings.KickUser Strings.KickUser Nothing
                                    ]

                            User.Left ->
                                Nothing
                in
                [ privilegeMenuItems, presenceMenuItems ]
                    |> List.filterMap identity
                    |> List.intersperse [ Menu.Separator ]
                    |> List.concat

            else
                []

        ( menu, clickable ) =
            if List.isEmpty menuItems then
                ( Html.nothing, HtmlA.nothing )

            else
                ( menuItems |> Menu.view shared id ( WlA.XRight, WlA.YCenter ) ( WlA.XLeft, WlA.YCenter )
                , WlA.clickable
                )
    in
    ( userId
    , Html.li []
        [ Wl.listItem
            [ HtmlA.classList [ ( "you", player == userId ) ]
            , clickable
            , HtmlA.id id
            ]
            [ Html.span [ HtmlA.class "user", HtmlA.title user.name ] [ Html.text user.name ]
            , Html.div [ HtmlA.class "compressed-terms" ] secondary
            , Html.span [ WlA.listItemSlot WlA.AfterItem ] score
            ]
        , menu
        ]
    )


userDetails : Shared -> Maybe Game -> User.Id -> User -> ( List (Html Global.Msg), List (Html Global.Msg) )
userDetails shared game userId user =
    let
        player =
            game |> Maybe.map .players |> Maybe.andThen (Dict.get userId)

        round =
            game |> Maybe.map .round

        details =
            [ Strings.Privileged |> Maybe.justIf (user.privilege == User.Privileged)
            , Strings.Ai |> Maybe.justIf (user.control == User.Computer)
            , round |> Maybe.andThen (\r -> Strings.Czar |> Maybe.justIf (Player.isCzar r userId))
            , playStateDetail round userId
            ]

        score =
            player |> Maybe.map (\p -> Strings.Score { total = p.score })
    in
    ( viewDetails shared details, viewDetails shared [ score ] )


playStateDetail : Maybe Round -> User.Id -> Maybe MdString
playStateDetail round userId =
    case round of
        Just (Round.P p) ->
            case Player.playState p userId of
                Player.Playing ->
                    Just Strings.StillPlaying

                Player.Played ->
                    Just Strings.Played

                Player.NotInRound ->
                    Nothing

        _ ->
            Nothing


viewDetails : Shared -> List (Maybe MdString) -> List (Html Global.Msg)
viewDetails shared details =
    details |> List.filterMap identity |> List.map (Lang.html shared) |> List.intersperse (Html.text " ")


viewCastButton : Auth -> List (Html.Attribute Global.Msg) -> List (Html Global.Msg)
viewCastButton auth attrs =
    [ Components.iconButtonStyled
        (List.concat
            [ [ HtmlA.class "cast-button"
              , auth |> Global.TryCast |> HtmlE.onClick
              ]
            , attrs
            ]
        )
        ( [ Icon.lg ], Icon.chromecast )
    ]