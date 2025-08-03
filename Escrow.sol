// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title SimpleEscrow
 * @dev Contrato escrow simplificado sin árbitro
 * - Usuario puede cancelar en 1 hora máximo
 * - Negocio puede cancelar en cualquier momento
 * - Si ambos confirman, el negocio recibe el dinero
 */
contract SimpleEscrow {
    // Estados posibles del escrow
    enum State { 
        AWAITING_CONFIRMATION,  // Esperando confirmaciones
        COMPLETED,             // Completado - dinero al negocio
        CANCELLED_BY_USER,     // Cancelado por usuario
        CANCELLED_BY_BUSINESS  // Cancelado por negocio
    }
    
    // Estructura para cada transacción escrow
    struct EscrowTransaction {
        address payable user;          // Usuario/Comprador
        address payable business;      // Negocio/Vendedor
        uint256 amount;               // Cantidad en wei
        State state;                  // Estado actual
        bool userConfirmed;           // Usuario confirmó recepción
        bool businessConfirmed;       // Negocio confirmó entrega
        string description;           // Descripción del pedido
        uint256 createdAt;           // Timestamp de creación
        uint256 cancelDeadline;      // Hasta cuándo puede cancelar el usuario (1 hora)
    }
    
    // Mapeo de ID de transacción a EscrowTransaction
    mapping(uint256 => EscrowTransaction) public escrowTransactions;
    
    // Contador para generar IDs únicos
    uint256 public transactionCounter;
    
    // Fee del contrato (en basis points, 100 = 1%)
    uint256 public escrowFee = 250; // 2.5%
    
    // Tiempo límite para cancelación de usuario (1 hora = 3600 segundos)
    uint256 public userCancelWindow = 3600;
    
    // Dirección del propietario del contrato
    address payable public owner;
    
    // Eventos
    event EscrowCreated(
        uint256 indexed transactionId,
        address indexed user,
        address indexed business,
        uint256 amount,
        string description
    );
    
    event UserConfirmed(
        uint256 indexed transactionId,
        address indexed user
    );
    
    event BusinessConfirmed(
        uint256 indexed transactionId,
        address indexed business
    );
    
    event EscrowCompleted(
        uint256 indexed transactionId,
        address indexed business,
        uint256 amount
    );
    
    event CancelledByUser(
        uint256 indexed transactionId,
        address indexed user,
        uint256 refundAmount
    );
    
    event CancelledByBusiness(
        uint256 indexed transactionId,
        address indexed business,
        uint256 refundAmount
    );
    
    // Modificadores
    modifier onlyOwner() {
        require(msg.sender == owner, "Solo el propietario puede ejecutar esta funcion");
        _;
    }
    
    modifier onlyUser(uint256 _transactionId) {
        require(msg.sender == escrowTransactions[_transactionId].user, "Solo el usuario puede ejecutar esta funcion");
        _;
    }
    
    modifier onlyBusiness(uint256 _transactionId) {
        require(msg.sender == escrowTransactions[_transactionId].business, "Solo el negocio puede ejecutar esta funcion");
        _;
    }
    
    modifier inState(uint256 _transactionId, State _state) {
        require(escrowTransactions[_transactionId].state == _state, "Estado de transaccion invalido");
        _;
    }
    
    modifier transactionExists(uint256 _transactionId) {
        require(_transactionId < transactionCounter, "La transaccion no existe");
        _;
    }
    
    constructor() {
        owner = payable(msg.sender);
    }
    
    /**
     * @dev Crear nueva transacción escrow
     * @param _business Dirección del negocio
     * @param _description Descripción del pedido
     */
    function createEscrow(
        address payable _business,
        string memory _description
    ) external payable returns (uint256) {
        require(msg.value > 0, "El monto debe ser mayor a 0");
        require(_business != address(0), "Direccion de negocio invalida");
        require(_business != msg.sender, "El usuario y negocio no pueden ser la misma persona");
        require(bytes(_description).length > 0, "La descripcion no puede estar vacia");
        
        uint256 transactionId = transactionCounter++;
        uint256 cancelDeadline = block.timestamp + userCancelWindow;
        
        escrowTransactions[transactionId] = EscrowTransaction({
            user: payable(msg.sender),
            business: _business,
            amount: msg.value,
            state: State.AWAITING_CONFIRMATION,
            userConfirmed: false,
            businessConfirmed: false,
            description: _description,
            createdAt: block.timestamp,
            cancelDeadline: cancelDeadline
        });
        
        emit EscrowCreated(transactionId, msg.sender, _business, msg.value, _description);
        
        return transactionId;
    }
    
    /**
     * @dev Usuario confirma que recibió el producto/servicio
     */
    function confirmReceived(uint256 _transactionId) 
        external 
        onlyUser(_transactionId)
        transactionExists(_transactionId)
        inState(_transactionId, State.AWAITING_CONFIRMATION)
    {
        escrowTransactions[_transactionId].userConfirmed = true;
        emit UserConfirmed(_transactionId, msg.sender);
        
        // Si el negocio ya confirmó, completar la transacción
        if (escrowTransactions[_transactionId].businessConfirmed) {
            _completeTransaction(_transactionId);
        }
    }
    
    /**
     * @dev Negocio confirma que entregó el producto/servicio
     */
    function confirmDelivered(uint256 _transactionId)
        external
        onlyBusiness(_transactionId)
        transactionExists(_transactionId)
        inState(_transactionId, State.AWAITING_CONFIRMATION)
    {
        escrowTransactions[_transactionId].businessConfirmed = true;
        emit BusinessConfirmed(_transactionId, msg.sender);
        
        // Si el usuario ya confirmó, completar la transacción
        if (escrowTransactions[_transactionId].userConfirmed) {
            _completeTransaction(_transactionId);
        }
    }
    
    /**
     * @dev Usuario cancela el pedido (solo dentro de 1 hora)
     */
    function cancelByUser(uint256 _transactionId)
        external
        onlyUser(_transactionId)
        transactionExists(_transactionId)
        inState(_transactionId, State.AWAITING_CONFIRMATION)
    {
        EscrowTransaction storage transaction = escrowTransactions[_transactionId];
        
        require(block.timestamp <= transaction.cancelDeadline, "Ya paso el tiempo limite para cancelar (1 hora)");
        require(!transaction.businessConfirmed, "El negocio ya confirmo la entrega, no se puede cancelar");
        
        transaction.state = State.CANCELLED_BY_USER;
        
        // Reembolsar el monto completo al usuario
        transaction.user.transfer(transaction.amount);
        
        emit CancelledByUser(_transactionId, msg.sender, transaction.amount);
    }
    
    /**
     * @dev Negocio cancela el pedido (puede hacerlo en cualquier momento)
     */
    function cancelByBusiness(uint256 _transactionId)
        external
        onlyBusiness(_transactionId)
        transactionExists(_transactionId)
        inState(_transactionId, State.AWAITING_CONFIRMATION)
    {
        EscrowTransaction storage transaction = escrowTransactions[_transactionId];
        
        require(!transaction.userConfirmed, "El usuario ya confirmo la recepcion, no se puede cancelar");
        
        transaction.state = State.CANCELLED_BY_BUSINESS;
        
        // Reembolsar el monto completo al usuario
        transaction.user.transfer(transaction.amount);
        
        emit CancelledByBusiness(_transactionId, msg.sender, transaction.amount);
    }
    
    /**
     * @dev Completar transacción - liberar fondos al negocio
     */
    function _completeTransaction(uint256 _transactionId) internal {
        EscrowTransaction storage transaction = escrowTransactions[_transactionId];
        
        transaction.state = State.COMPLETED;
        
        uint256 fee = (transaction.amount * escrowFee) / 10000;
        uint256 businessAmount = transaction.amount - fee;
        
        // Transferir fee al propietario del contrato
        if (fee > 0) {
            owner.transfer(fee);
        }
        
        // Transferir fondos al negocio
        transaction.business.transfer(businessAmount);
        
        emit EscrowCompleted(_transactionId, transaction.business, businessAmount);
    }
    
    /**
     * @dev Verificar si el usuario puede cancelar
     */
    function canUserCancel(uint256 _transactionId) 
        external 
        view 
        transactionExists(_transactionId)
        returns (bool canCancel, uint256 timeLeft) 
    {
        EscrowTransaction storage transaction = escrowTransactions[_transactionId];
        
        if (transaction.state != State.AWAITING_CONFIRMATION) {
            return (false, 0);
        }
        
        if (transaction.businessConfirmed) {
            return (false, 0);
        }
        
        if (block.timestamp > transaction.cancelDeadline) {
            return (false, 0);
        }
        
        return (true, transaction.cancelDeadline - block.timestamp);
    }
    
    /**
     * @dev Obtener detalles de una transacción
     */
    function getTransaction(uint256 _transactionId) 
        external 
        view 
        transactionExists(_transactionId)
        returns (
            address user,
            address business,
            uint256 amount,
            State state,
            bool userConfirmed,
            bool businessConfirmed,
            string memory description,
            uint256 createdAt,
            uint256 cancelDeadline,
            bool canStillCancel
        )
    {
        EscrowTransaction storage transaction = escrowTransactions[_transactionId];
        
        bool canCancel = (
            transaction.state == State.AWAITING_CONFIRMATION &&
            !transaction.businessConfirmed &&
            block.timestamp <= transaction.cancelDeadline
        );
        
        return (
            transaction.user,
            transaction.business,
            transaction.amount,
            transaction.state,
            transaction.userConfirmed,
            transaction.businessConfirmed,
            transaction.description,
            transaction.createdAt,
            transaction.cancelDeadline,
            canCancel
        );
    }
    
    /**
     * @dev Obtener todas las transacciones de un usuario
     */
    function getUserTransactions(address _user) 
        external 
        view 
        returns (uint256[] memory transactionIds) 
    {
        uint256 count = 0;
        
        // Contar transacciones del usuario
        for (uint256 i = 0; i < transactionCounter; i++) {
            if (escrowTransactions[i].user == _user) {
                count++;
            }
        }
        
        // Crear array con los IDs
        transactionIds = new uint256[](count);
        uint256 index = 0;
        
        for (uint256 i = 0; i < transactionCounter; i++) {
            if (escrowTransactions[i].user == _user) {
                transactionIds[index] = i;
                index++;
            }
        }
        
        return transactionIds;
    }
    
    /**
     * @dev Obtener todas las transacciones de un negocio
     */
    function getBusinessTransactions(address _business) 
        external 
        view 
        returns (uint256[] memory transactionIds) 
    {
        uint256 count = 0;
        
        // Contar transacciones del negocio
        for (uint256 i = 0; i < transactionCounter; i++) {
            if (escrowTransactions[i].business == _business) {
                count++;
            }
        }
        
        // Crear array con los IDs
        transactionIds = new uint256[](count);
        uint256 index = 0;
        
        for (uint256 i = 0; i < transactionCounter; i++) {
            if (escrowTransactions[i].business == _business) {
                transactionIds[index] = i;
                index++;
            }
        }
        
        return transactionIds;
    }
    
    /**
     * @dev Cambiar fee del escrow (solo propietario)
     */
    function setEscrowFee(uint256 _newFee) external onlyOwner {
        require(_newFee <= 1000, "El fee no puede ser mayor al 10%"); // Máximo 10%
        escrowFee = _newFee;
    }
    
    /**
     * @dev Cambiar tiempo límite de cancelación (solo propietario)
     */
    function setCancelWindow(uint256 _newWindowInSeconds) external onlyOwner {
        require(_newWindowInSeconds >= 300, "Minimo 5 minutos"); // Mínimo 5 minutos
        require(_newWindowInSeconds <= 86400, "Maximo 24 horas"); // Máximo 24 horas
        userCancelWindow = _newWindowInSeconds;
    }
    
    /**
     * @dev Retirar fees acumuladas (solo propietario)
     */
    function withdrawFees() external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No hay fees para retirar");
        
        owner.transfer(balance);
    }
    
    /**
     * @dev Obtener balance del contrato
     */
    function getContractBalance() external view returns (uint256) {
        return address(this).balance;
    }
    
    /**
     * @dev Transferir propiedad del contrato
     */
    function transferOwnership(address payable _newOwner) external onlyOwner {
        require(_newOwner != address(0), "Nueva direccion de propietario invalida");
        owner = _newOwner;
    }
}