// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// V2 修改：引入标准 IERC721 接口，用于原子化转移 NFT 资产
interface IERC721 {
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
}

contract SkillNet {
    // 链上事件定义
    event CourseCompleted(address indexed user, uint256 course_id, uint256 points_gained);
    event TaskCompleted(address indexed user, uint256 task_id, uint256 points_gained);
    event ItemRedeemed(address indexed user, uint256 item_id, uint256 cost);
    // V2 修改：增加 NFT 兑换专属事件，方便前端（肖同学）监听并渲染勋章墙
    event NFTRedeemed(address indexed user, uint256 item_id, address nft_address, uint256 token_id);

    struct UserState {
        uint256 consecutive_days;
        uint256 last_learn_timestamp;
        uint256 total_points;
        uint256 staked_amount;
        uint256 nonce;
    }

    struct LeaderboardUser {
        address account;
        uint256 points;
    }

    // 肖同学核心诉求一：定义商城商品结构体，用于全量返回
    struct MallItem {
        uint256 item_id;
        uint256 price;
        bool is_active;
        // V2 修改：新增 NFT 资产支持字段
        bool is_nft;            // 是否为 NFT 资产
        address nft_address;    // NFT 对应的合约地址（若不是NFT则为 address(0)）
        uint256 nft_token_id;   // NFT 的 Token ID
    }

    // 核心账本
    mapping(address => UserState) public user_states;
    mapping(address => mapping(uint256 => bool)) public course_completed;
    mapping(address => mapping(uint256 => bool)) public task_completed; // 任务完成记录
    
    address public owner;               
    address public ai_verifier_address; 
    uint256 private security_salt;
    LeaderboardUser[] public top_users;
    
    // 商城底层存储结构重构
    mapping(uint256 => MallItem) public mall_items;
    uint256[] public mall_item_ids; // 专门用来存放所有上架商品的 ID 数组，供遍历使用

    modifier onlyOwner() {
        require(msg.sender == owner, "Not Contract Owner");
        _;
    }

    constructor(address _ai_verifier, uint256 _salt) {
        owner = msg.sender;
        ai_verifier_address = _ai_verifier;
        security_salt = _salt;
    }

    /**
     * @notice 课程结算网关
     * V2 修改：新增 `video_valid` 参数，要求 AI 验证引擎核实用户视频观看行为
     */
    function complete_course(
        uint256 course_id,
        uint256 score,
        uint256 correct_rate,
        uint256 difficulty,
        bool video_valid, // V2 新增：视频观看达标标识
        bytes memory signature
    ) external {
        require(!course_completed[msg.sender][course_id], "Already Completed");
        require(video_valid, "Video requirement not met"); // 拦截未完成视频观看的用户
        require(signature.length == 65, "Invalid signature length");

        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(signature, 32))
            s := mload(add(signature, 64))
            v := byte(0, mload(add(signature, 96)))
        }

        UserState storage state = user_states[msg.sender];
        // 密码学三端哈希对齐 (V2 修改：将视频观看结果 video_valid 捆绑进验签哈希)
        bytes32 msgHash = keccak256(abi.encodePacked(
            msg.sender, 
            course_id, 
            score, 
            correct_rate, 
            difficulty, 
            video_valid,
            state.nonce
        ));
        bytes32 ethSignedMessageHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", msgHash));
        require(ecrecover(ethSignedMessageHash, v, r, s) == ai_verifier_address, "Invalid AI Verification Signature");
        
        // 连击天数判定
        uint256 nowTime = block.timestamp;
        if (state.last_learn_timestamp > 0 && (nowTime - state.last_learn_timestamp) <= 86400) {
            state.consecutive_days = state.consecutive_days + 1 > 30 ? 30 : state.consecutive_days + 1;
        } else {
            state.consecutive_days = 1;
        }
        state.last_learn_timestamp = nowTime;

        uint256 final_reward = _calculate_reward(difficulty, correct_rate, state.consecutive_days, state.staked_amount);
        state.total_points += final_reward;
        course_completed[msg.sender][course_id] = true;
        state.nonce++; 

        _update_leaderboard(msg.sender, state.total_points);
        emit CourseCompleted(msg.sender, course_id, final_reward);
    }

    /**
     * @notice 极客任务大厅核心清算网关
     */
    function complete_task(
        uint256 task_id,
        uint256 reward_points,
        bytes memory signature
    ) external {
        require(!task_completed[msg.sender][task_id], "Task Already Completed");
        require(signature.length == 65, "Invalid signature length");

        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(signature, 32))
            s := mload(add(signature, 64))
            v := byte(0, mload(add(signature, 96)))
        }

        UserState storage state = user_states[msg.sender];
        // 任务大厅专属防伪哈希：绑定用户、任务ID、积分值、个体nonce
        bytes32 msgHash = keccak256(abi.encodePacked(
            msg.sender,
            task_id,
            reward_points,
            state.nonce
        ));
        bytes32 ethSignedMessageHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", msgHash));
        require(ecrecover(ethSignedMessageHash, v, r, s) == ai_verifier_address, "Invalid AI Task Signature");
        
        // 记账发放积分
        state.total_points += reward_points;
        task_completed[msg.sender][task_id] = true;
        state.nonce++; // nonce 递增，严防重放攻击

        _update_leaderboard(msg.sender, state.total_points);
        emit TaskCompleted(msg.sender, task_id, reward_points);
    }

    // 内部纯函数：动态奖励计算
    function _calculate_reward(
        uint256 difficulty, 
        uint256 correct_rate, 
        uint256 consecutive_days, 
        uint256 staked_amount
    ) internal pure returns (uint256) {
        uint256 reward = 100 * (100 + difficulty) / 100 * (100 + correct_rate) / 100;
        uint256 streak = consecutive_days > 30 ? 30 : consecutive_days;
        reward = reward * (100 + streak) / 100;
        if (staked_amount >= 5000) {
            reward = (reward * 13) / 10;
        } else if (staked_amount >= 1000) {
            reward = (reward * 11) / 10;
        }
        return reward;
    }

    /**
     * @notice 管理端：商品上架逻辑
     * V2 修改：允许录入 NFT 地址与 TokenID 
     */
    function add_mall_item(
        uint256 item_id, 
        uint256 price,
        bool is_nft,
        address nft_address,
        uint256 nft_token_id
    ) external onlyOwner {
        require(price > 0, "Price must be positive");
        
        // 如果是全新商品，追加到 ID 数组中以便前端全量拉取
        if (!mall_items[item_id].is_active) {
            mall_item_ids.push(item_id);
        }
        
        mall_items[item_id] = MallItem({
            item_id: item_id, 
            price: price, 
            is_active: true,
            is_nft: is_nft,
            nft_address: nft_address,
            nft_token_id: nft_token_id
        });
    }

    // 用户端：商城全量数据遍历 Getter 接口
    function get_all_mall_items() external view returns (MallItem[] memory) {
        uint256 len = mall_item_ids.length;
        MallItem[] memory items = new MallItem[](len);
        for (uint256 i = 0; i < len; i++) {
            items[i] = mall_items[mall_item_ids[i]];
        }
        return items;
    }

    /**
     * @notice 用户端：商品与 NFT 兑换网关
     * V2 修改：增加原子化 NFT 转账触发逻辑 [cite: 53]
     */
    function redeem_item(uint256 item_id) external {
        MallItem memory item = mall_items[item_id];
        require(item.is_active, "Item Not Found");
        
        UserState storage state = user_states[msg.sender];
        require(state.total_points >= item.price, "Insufficient Balance");

        // 1. 扣除积分
        state.total_points -= item.price;

        // 2. 判定并处理资产转移
        if (item.is_nft) {
            require(item.nft_address != address(0), "Invalid NFT Address");
            // 调用外部 NFT 合约，将 NFT 从合约所有者（或国库）转移给用户
            // 前提：owner 已在 NFT 合约中通过 setApprovalForAll 授权给本智能合约
            IERC721(item.nft_address).safeTransferFrom(owner, msg.sender, item.nft_token_id);
            
            emit NFTRedeemed(msg.sender, item_id, item.nft_address, item.nft_token_id);
        }

        emit ItemRedeemed(msg.sender, item_id, item.price);
    }

    // 积分质押模型
    function stake_points(uint256 amount) external {
        user_states[msg.sender].staked_amount += amount;
    }

    // 排行榜冒泡排序
    function _update_leaderboard(address user, uint256 points) internal {
        for (uint256 i = 0; i < top_users.length; i++) {
            if (top_users[i].account == user) {
                _remove(i);
                break;
            }
        }
        top_users.push(LeaderboardUser(user, points));
        uint256 len = top_users.length;
        for (uint256 i = 0; i < len; i++) {
            for (uint256 j = i + 1; j < len; j++) {
                if (top_users[j].points > top_users[i].points) {
                    LeaderboardUser memory temp = top_users[i];
                    top_users[i] = top_users[j];
                    top_users[j] = temp;
                }
            }
        }

        while (top_users.length > 5) {
            top_users.pop();
        }
    }

    function _remove(uint256 index) internal {
        require(index < top_users.length, "Index out of bounds");
        for (uint256 i = index; i < top_users.length - 1; i++) {
            top_users[i] = top_users[i + 1];
        }
        top_users.pop();
    }

    function get_top_five() external view returns (LeaderboardUser[] memory) {
        return top_users;
    }

    function get_user_status(address account) external view returns (UserState memory) {
        return user_states[account];
    }
}