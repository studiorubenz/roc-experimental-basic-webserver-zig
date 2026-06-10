port module Main exposing (main)

{-| Chat frontend for the Roc basic-webserver WebSocket platform.

Elm 0.19 has no built-in WebSocket support, so the socket lives in a few
lines of JS (see the page served by main.roc) and talks to Elm via ports:
outgoing messages through `sendMessage`, incoming ones through
`messageReceived`, connection state through `socketState`.

Wire format (shared with examples/chat): "name<TAB>text".

-}

import Browser
import Html exposing (Html, button, div, form, h1, input, li, p, text, ul)
import Html.Attributes exposing (autofocus, disabled, placeholder, value)
import Html.Events exposing (onInput, onSubmit)


port sendMessage : String -> Cmd msg


port messageReceived : (String -> msg) -> Sub msg


port socketState : (Bool -> msg) -> Sub msg


type alias Model =
    { name : String
    , joined : Bool
    , connected : Bool
    , draft : String
    , messages : List String
    }


type Msg
    = NameChanged String
    | Join
    | DraftChanged String
    | Send
    | Received String
    | SocketState Bool


main : Program () Model Msg
main =
    Browser.element
        { init = init
        , update = update
        , view = view
        , subscriptions = subscriptions
        }


init : () -> ( Model, Cmd Msg )
init _ =
    ( { name = ""
      , joined = False
      , connected = False
      , draft = ""
      , messages = []
      }
    , Cmd.none
    )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        NameChanged name ->
            ( { model | name = name }, Cmd.none )

        Join ->
            if String.trim model.name == "" then
                ( model, Cmd.none )

            else
                ( { model | joined = True }
                , sendMessage (String.trim model.name ++ "\t/joined")
                )

        DraftChanged draft ->
            ( { model | draft = draft }, Cmd.none )

        Send ->
            if model.draft == "" then
                ( model, Cmd.none )

            else
                ( { model | draft = "" }
                , sendMessage (String.trim model.name ++ "\t" ++ model.draft)
                )

        Received line ->
            ( { model | messages = model.messages ++ [ line ] }, Cmd.none )

        SocketState open ->
            ( { model | connected = open }, Cmd.none )


subscriptions : Model -> Sub Msg
subscriptions _ =
    Sub.batch
        [ messageReceived Received
        , socketState SocketState
        ]


view : Model -> Html Msg
view model =
    div []
        [ h1 [] [ text "Roc + Elm chat" ]
        , p []
            [ text
                (if model.connected then
                    "connected — open this page in several tabs"

                 else
                    "connecting..."
                )
            ]
        , if model.joined then
            chatView model

          else
            joinView model
        ]


joinView : Model -> Html Msg
joinView model =
    form [ onSubmit Join ]
        [ input
            [ placeholder "Your name"
            , value model.name
            , onInput NameChanged
            , autofocus True
            ]
            []
        , button [ disabled (String.trim model.name == "") ] [ text "Join" ]
        ]


chatView : Model -> Html Msg
chatView model =
    div []
        [ ul [] (List.map (\line -> li [] [ text line ]) model.messages)
        , form [ onSubmit Send ]
            [ input
                [ placeholder "Say something..."
                , value model.draft
                , onInput DraftChanged
                , autofocus True
                ]
                []
            , button [ disabled (model.draft == "") ] [ text "Send" ]
            ]
        ]
