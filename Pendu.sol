//SPDX-License-Identifier: MIT
pragma solidity >=0.8.14;

import "./IPendu.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import {VRFConsumerBaseV2Plus} from "@chainlink/contracts@1.2.0/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts@1.2.0/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

// Guessing Game ("Jeu du Pendu" in French)
// Game intervals : customizable
// The players bet tokens
// The program automatically generate a random number (to be guessed by players) using Chainlink oracle. 
// Number of Attempts : Illimited


contract Pendu is IPendu, VRFConsumerBaseV2Plus {

    // Attributes to handle requests to Chainlink oracle.

    event RequestSent(uint256 requestId, uint32 numWords);
    event RequestFulfilled(uint256 requestId, uint256[] randomWords);

    struct RequestStatus {
        bool fulfilled; // whether the request has been successfully fulfilled
        bool exists; // whether a requestId exists
        uint256[] randomWords;
    }
    mapping(uint256 => RequestStatus) public s_requests; /* requestId --> requestStatus */

    // Your subscription ID.
    uint256 public s_subscriptionId;

    // Past request IDs.
    uint256[] public requestIds;
    uint256 public lastRequestId;

    // The gas lane to use, which specifies the maximum gas price to bump to.
    // For a list of available gas lanes on each network,
    // see https://docs.chain.link/docs/vrf/v2-5/supported-networks
    bytes32 public keyHash =
        0x787d74caea10b2b357790d5b5247c2f63d1d91572a9846f780606e4d953677ae;

    // Depends on the number of requested values that you want sent to the
    // fulfillRandomWords() function. Storing each word costs about 20,000 gas,
    // so 100,000 is a safe default for this example contract. Test and adjust
    // this limit based on the network that you select, the size of the request,
    // and the processing of the callback request in the fulfillRandomWords()
    // function.
    uint32 public callbackGasLimit = 100000;

    // The default is 3, but you can set this higher.
    uint16 public requestConfirmations = 3;

    // For this example, retrieve 2 random values in one request.
    // Cannot exceed VRFCoordinatorV2_5.MAX_NUM_WORDS.
    uint32 public numWords = 2;


    // Attributes to manage games

    uint256 public gameCount = 0;

    struct Game {
        uint256 amountToBet;
        address launcher;
        address challenger;
        uint256 lowerLimit;
        uint256 upperLimit;
        uint256 randomNumber;
        GameStatus status;
        Winner winner;
    }

    enum GameStatus {
        INITIALIZED,
        ONGOING,
        FINISHED
    }

    enum Winner {
        NONE,
        LAUNCHER,
        CHALLENGER
    }

    mapping(address => string) players;
    mapping(uint256 => Game) public games;
    mapping(uint256 => bool) isGame;
    mapping(address => mapping(uint256 => bool)) playerHasPaid;
    mapping(uint256 => address) currentGamePlayer;

    //Mapping to bind a game to a request ID to chainlink
    mapping(uint256 => uint256) gameRequests; /* requestId --> gameId */

    event NewGameEvent(uint256);
    event GameIntervalsUpdatedEvent(uint256, uint256, uint256);
    event GameAmountUpdatedEvent(uint256, uint256);
    event PlayerPaidEvent(address, uint256);
    event GameStatusUpdatedEvent(uint256, GameStatus);
    event NewGuessedNumberEvent(address, uint256, NumberStatus);


        /**
     * HARDCODED FOR SEPOLIA
     * COORDINATOR: 0x9DdfaCa8183c41ad55329BdeeD9F6A8d53168B1B
     */
    constructor(uint256 subscriptionId)
        VRFConsumerBaseV2Plus(0x9DdfaCa8183c41ad55329BdeeD9F6A8d53168B1B)
    {
        s_subscriptionId = subscriptionId;
    }

     // Here come the modifiers

    //Used to make sure a game exists
    modifier gameExist(uint256 _gameId) {
        require(isGame[_gameId], "The game doesn't exist !");
        _;
    }

    // Verify if the game is in the "Initialization Phase" where players didn't start playing yet.
    modifier gameIsInitialized(uint256 _gameId) {
        require(
            games[_gameId].status == GameStatus.INITIALIZED,
            "The game isn't in the initialization process !"
        );
        _;
    }

    // Verify if the game is ongoing, meaning at least one of the players played.
    modifier gameIsOngoing(uint256 _gameId) {
        require(
            games[_gameId].status == GameStatus.ONGOING,
            "The game isn't ongoing !"
        );
        _;
    }

    // Verify if the game is finished
    modifier gameIsFinished(uint256 _gameId) {
        require(
            games[_gameId].status == GameStatus.FINISHED,
            "The current game isn't finished !"
        );
        _;
    }

    // Verify it's the game's launcher
    modifier onlyLauncher(uint256 _gameId) {
        require(
            games[_gameId].launcher == msg.sender,
            "You're not the launcher of this game"
        );
        _;
    }

    // Verify it's one of the two game's players
    modifier onlyPlayer(uint256 _gameId) {
        require(
            msg.sender == games[_gameId].launcher ||
                msg.sender == games[_gameId].challenger,
            "You're not a player of this game"
        );
        _;
    }

    // Assumes the subscription is funded sufficiently.
    // @param enableNativePayment: Set to `true` to enable payment in native tokens, or
    // `false` to pay in LINK
    function requestRandomWords(bool enableNativePayment)
        internal
        returns (uint256 requestId)
    {
        // Will revert if subscription is not set and funded.
        requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: keyHash,
                subId: s_subscriptionId,
                requestConfirmations: requestConfirmations,
                callbackGasLimit: callbackGasLimit,
                numWords: numWords,
                extraArgs: VRFV2PlusClient._argsToBytes(
                    VRFV2PlusClient.ExtraArgsV1({
                        nativePayment: enableNativePayment
                    })
                )
            })
        );
        s_requests[requestId] = RequestStatus({
            randomWords: new uint256[](0),
            exists: true,
            fulfilled: false
        });
        requestIds.push(requestId);
        lastRequestId = requestId;
        emit RequestSent(requestId, numWords);
        return requestId;
    }

    function fulfillRandomWords(
        uint256 _requestId,
        uint256[] calldata _randomWords
    ) internal override {
        require(s_requests[_requestId].exists, "request not found");
        s_requests[_requestId].fulfilled = true;
        s_requests[_requestId].randomWords = _randomWords;
        uint256 gameId = gameRequests[_requestId];
        uint256 randomNumber = (_randomWords[0] %
            (games[gameId].upperLimit - games[gameId].lowerLimit + 1)) +
            games[gameId].lowerLimit;
        games[gameId].randomNumber = randomNumber;
        emit RequestFulfilled(_requestId, _randomWords);
    }

    function getRequestStatus(uint256 _requestId)
        external
        view
        returns (bool fulfilled, uint256[] memory randomWords)
    {
        require(s_requests[_requestId].exists, "request not found");
        RequestStatus memory request = s_requests[_requestId];
        return (request.fulfilled, request.randomWords);
    }


    // The users must start by setting their name
    function setPlayerName(string memory _playerName) public {
        players[msg.sender] = _playerName;
    }

    // Create and intitialize a new game
    function newGame(
        address _player2Addr,
        uint256 _amountToBet,
        uint256 _lowerLimit,
        uint256 _upperLimit
    ) public {
        require(msg.sender != _player2Addr, "You can't play against yourself");
        require(_amountToBet >= 0, "The betting amount should be positive");
        require(
            _lowerLimit < _upperLimit,
            "The lower limit should be less than the upper"
        );
        gameCount++;
        Game storage game = games[gameCount];
        isGame[gameCount] = true;
        game.amountToBet = _amountToBet;
        game.launcher = msg.sender;
        game.challenger = _player2Addr;
        game.lowerLimit = _lowerLimit;
        game.upperLimit = _upperLimit;
        game.status = GameStatus.INITIALIZED;

        uint256 requestId = generateRandomNumber(gameCount);
        gameRequests[requestId] = gameCount;

        emit NewGameEvent(gameCount);
    }

    // Generate a "pseudo" random number between a lower and an upper limit
    function generateRandomNumber(uint256 _gameId)
        internal
        gameExist(_gameId)
        returns (uint256)
    {
        // Let's ensure the number is between the lower and the upper limit
        // The modulo of the generated number divided by (upper - lower + 1) will produce a number less than or equal their difference
        // Then adding this number to lowerLimit ensure the final will be at least the lower and at most the upper number.
        uint256 requestId = requestRandomWords(true);
        gameRequests[requestId] = _gameId;
        return requestId;
    }

    // The launcher of the game can update the intervals as long as no one played yet
    function updateGameIntervals(
        uint256 _gameId,
        uint256 _newLowerLimit,
        uint256 _newUpperLimit
    )
        external
        gameExist(_gameId)
        onlyLauncher(_gameId)
        gameIsInitialized(_gameId)
    {
        games[_gameId].lowerLimit = _newLowerLimit;
        games[_gameId].upperLimit = _newUpperLimit;
        uint256 requestId = generateRandomNumber(_gameId);
        gameRequests[requestId] = _gameId;

        emit GameIntervalsUpdatedEvent(
            _gameId,
            _newLowerLimit,
            _newUpperLimit
        );
    }

    // The launcher of the game can update the amount to bet as long as no one played yet
    function updateAmountToBet(uint256 _gameId, uint256 _newAmount)
        external
        gameExist(_gameId)
        onlyLauncher(_gameId)
        gameIsInitialized(_gameId)
    {
        require(_newAmount > 0, "The amount should be greater than 0");
        games[_gameId].amountToBet = _newAmount;
        emit GameAmountUpdatedEvent(_gameId, _newAmount);
    }

    //The users should pay before playing
    function payToPlay(uint256 _gameId)
        external
        payable
        gameExist(_gameId)
        onlyPlayer(_gameId)
        gameIsInitialized(_gameId)
    {
        require(playerHasPaid[msg.sender][_gameId] != true, "You already paid");
        require(
            msg.value == games[_gameId].amountToBet,
            "Make sure to send the right amount of ether"
        );
        playerHasPaid[msg.sender][_gameId] = true;

        if (bothPlayersPaid(_gameId)) {
            games[_gameId].status = GameStatus.ONGOING;
            emit GameStatusUpdatedEvent(_gameId, games[_gameId].status);
        }

        emit PlayerPaidEvent(msg.sender, _gameId);
    }

    // Verify if both players of a game paid the betting amount
    function bothPlayersPaid(uint256 _gameId) internal view returns (bool) {
        address launcher = games[_gameId].launcher;
        address challenger = games[_gameId].challenger;
        if (
            playerHasPaid[launcher][_gameId] == true &&
            playerHasPaid[challenger][_gameId] == true
        ) return true;
        else return false;
    }

    // The players try to guess the correct number randomly generated.
    function guessTheCorrectNumber(uint256 _gameId, uint256 _guessedNumber)
        external
        payable
        gameExist(_gameId)
        onlyPlayer(_gameId)
        gameIsOngoing(_gameId)
        returns (NumberStatus)
    {
        require(
            currentGamePlayer[_gameId] ==
                0x0000000000000000000000000000000000000000 ||
                currentGamePlayer[_gameId] == msg.sender,
            "It's not your turn to play"
        );
        require(
            _guessedNumber >= games[_gameId].lowerLimit &&
                _guessedNumber <= games[_gameId].upperLimit,
            "The number is out of limits"
        );

        // Setting the next user to play
        if (msg.sender == games[_gameId].launcher)
            currentGamePlayer[_gameId] = games[_gameId].challenger;
        else currentGamePlayer[_gameId] = games[_gameId].launcher;

        // Verifying if the number provided by the player is the correct one
        if (_guessedNumber > games[_gameId].randomNumber) {
            emit NewGuessedNumberEvent(
                msg.sender,
                _gameId,
                NumberStatus.GREATER
            );
            return NumberStatus.GREATER;
        } else if (_guessedNumber < games[_gameId].randomNumber) {
            emit NewGuessedNumberEvent(
                msg.sender,
                _gameId,
                NumberStatus.SMALLER
            );
            return NumberStatus.SMALLER;
        } else {
            emit NewGuessedNumberEvent(msg.sender, _gameId, NumberStatus.EQUAL);

            if (msg.sender == games[_gameId].launcher)
                games[_gameId].winner = Winner.LAUNCHER;
            else if (msg.sender == games[_gameId].challenger)
                games[_gameId].winner = Winner.CHALLENGER;

            //Pay the winner and close the game
            payable(msg.sender).transfer(
                games[_gameId].amountToBet * (10**18) * 2
            );
            games[_gameId].status = GameStatus.FINISHED;

            emit GameStatusUpdatedEvent(_gameId, games[_gameId].status);

            return NumberStatus.EQUAL;
        }
    }

    // Launch another base with the current game information, in case the players want to play again.
    function anotherGame(uint256 _gameId)
        external
        gameExist(_gameId)
        onlyLauncher(_gameId)
        gameIsFinished(_gameId)
    {
        newGame(
            games[_gameId].challenger,
            games[_gameId].amountToBet,
            games[_gameId].lowerLimit,
            games[_gameId].upperLimit
        );
    }

    // In case the player send tokens by accident to the contract
    mapping(address => uint256) balance;

    receive() external payable {
        balance[msg.sender] += msg.value;
    }

    function withdrawBalance() public payable {
        require(balance[msg.sender] > 0, "You don't have funds");
        payable(msg.sender).transfer(balance[msg.sender]);
    }
}

// Next steps
// Permettre le jeu à 2 en créant une partie qui prend en compte l'addresse des joueurs - OK
// Permettre aux joueurs de choisir l'intervalle de jeu - OK
// permettre aux joeurs de recommencer la partie OK
// Permettre aux joeurs de mettre des tokens en jeu qui seront sauvegardés par le smart contract et transférés au gagnant OK
// Ajout des contrôles d'accès - OK
// Faire en sorte que les joeurs doivent jouer l'un après l'autre OK
// Ajout des évènements pour le frontend OK
// Améliorer ce que la fonction guess retourne OK
// Ajout d'une interface pour le contrat OK
// Rendre le nombre réellement aléatoire grâce aux oracles : 69483838576072029219495071561698310382371810567704335300510833802519375536971
// Gestion d'erreurs
// Permettre aux joueurs de laisser leurs gains dans le contrat et ne payer pour jouer que si leur solde du contrat est plus petit que le montant à jouer.
// Sécurité du contrat intelligent
// Permettre le jeu en plusieurs manches
